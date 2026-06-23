<template>
  <div class="browser">
    <header class="toolbar">
      <h1>Local Cast</h1>
      <div class="toolbar-right">
        <CastButton />
        <button class="logout-btn" @click="handleLogout">Logout</button>
      </div>
    </header>

    <div class="search-bar">
      <input
        v-model="searchQuery"
        type="text"
        placeholder="Search files and folders..."
        class="search-input"
        @input="onSearchInput"
      />
      <button v-if="searchQuery" class="search-clear" @click="clearSearch">✕</button>
    </div>

    <nav v-if="!isSearching" class="breadcrumb">
      <button @click="navigateTo('')">Home</button>
      <template v-for="(crumb, i) in breadcrumbs" :key="i">
        <span class="sep">/</span>
        <button @click="navigateTo(crumb.prefix)">{{ crumb.name }}</button>
      </template>
    </nav>

    <div v-if="loading" class="loading-state">
      <LoadingSpinner /> Loading...
    </div>

    <div v-else-if="error" class="error-state">
      {{ error }}
      <button @click="load(currentPrefix)">Retry</button>
    </div>

    <div v-else class="file-list">
      <div
        v-for="folder in displayFolders"
        :key="folder"
        class="item folder"
        @click="navigateTo(folder)"
      >
        <span class="icon">📁</span>
        <span class="name">{{ isSearching ? folder : displayName(folder) }}</span>
      </div>
      <div
        v-for="file in displayFiles"
        :key="file.key"
        class="item file"
        @click="playFile(file)"
      >
        <span class="icon">{{ isVideoFile(file.name) ? '🎬' : '🎵' }}</span>
        <span class="name">{{ isSearching ? file.key : file.name }}</span>
        <span class="size">{{ formatSize(file.size) }}</span>
        <button
          v-if="castAvailable"
          class="cast-file-btn"
          title="Cast to device"
          @click.stop="playFile(file, true)"
        >📺</button>
      </div>
      <div v-if="!displayFolders.length && !displayFiles.length" class="empty">
        {{ isSearching ? 'No results found' : 'No media files found' }}
      </div>
    </div>

    <!-- Local playback -->
    <div v-if="playbackUrl" class="player">
      <div class="player-header">
        <span class="player-title">{{ playbackTitle }}</span>
        <button class="close-btn" @click="closePlayer">✕</button>
      </div>
      <video
        v-if="playbackIsVideo"
        :src="playbackUrl"
        controls
        autoplay
        class="media-player"
      />
      <audio
        v-else
        :src="playbackUrl"
        controls
        autoplay
        class="media-player"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
/**
 * Media browser view. Lists S3 folders and files with breadcrumb navigation,
 * plays media via Chromecast when available or falls back to local HTML5 playback.
 */
import { ref, computed, onMounted, watch } from 'vue';
import { useRouter, useRoute } from 'vue-router';
import { apiBrowse, apiSearch, apiGetSignedUrl, apiLogout } from '@/services/api';
import { castAvailable, castState, castMedia, castGetContentType, castIsVideo } from '@/services/cast';
import CastButton from './CastButton.vue';
import LoadingSpinner from './LoadingSpinner.vue';

const router = useRouter();
const route = useRoute();

const currentPrefix = ref('');
const folders = ref<string[]>([]);
const files = ref<{ key: string; name: string; size: number; lastModified: string }[]>([]);
const loading = ref(false);
const error = ref('');

const playbackUrl = ref('');
const playbackTitle = ref('');
const playbackIsVideo = ref(false);

const searchQuery = ref('');
const isSearching = ref(false);
const searchFolders = ref<string[]>([]);
const searchFiles = ref<{ key: string; name: string; size: number; lastModified: string }[]>([]);
let searchDebounceTimer: ReturnType<typeof setTimeout> | null = null;

const displayFolders = computed(() => isSearching.value ? searchFolders.value : folders.value);
const displayFiles = computed(() => isSearching.value ? searchFiles.value : files.value);

/** 
 * Builds breadcrumb segments from the current S3 prefix for navigation. 
 * 
 * @returns An array of breadcrumb objects with 'name' and 'prefix' for each segment
 */
const breadcrumbs = computed(() => {
  if (!currentPrefix.value) return [];
  const parts = currentPrefix.value.replace(/\/$/, '').split('/');
  return parts.map((part, i) => ({
    name: part,
    prefix: parts.slice(0, i + 1).join('/') + '/',
  }));
});

/** 
 * Extracts the last path segment from a folder prefix for display. 
 * 
 * @param folder full S3 folder prefix (e.g. 'movies/action/')
 * @returns last segment of the path (e.g. 'action') for display purposes
 */
function displayName(folder: string): string {
  const parts = folder.replace(/\/$/, '').split('/');
  return parts[parts.length - 1];
}

/**
 * Content type detection based on file extension for determining if a file is a video.
 * 
 * @param name file name to check (e.g. 'movie.mp4')
 * @returns true if the file is recognized as a video type, false otherwise
 */
function isVideoFile(name: string): boolean {
  return castIsVideo(name);
}

/** 
 * Formats a byte count into a human-readable size string.
 * 
 * @param bytes file size (in bytes)
 * @returns a formatted string like '1.2 MB' or '850 KB'
 */
function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

/**
 * Closes the local playback player. If media is currently casting, it will continue
 */
function closePlayer() {
  playbackUrl.value = '';
}

/**
 * Logs out the user by calling the API and then redirects to the login page.
 */
async function handleLogout() {
  await apiLogout();
  router.push('/login');
}

/**
 * Navigates to a new S3 prefix by updating the route. Also clears any active search state.
 * 
 * @param prefix full s3 prefix to navigate to (e.g. 'movies/action/')
 */
function navigateTo(prefix: string) {
  clearSearch();
  router.push('/' + prefix);
}

/**
 * Handles input events on the search bar with debouncing. 
 * Initiates a search when the user stops typing for 300ms and the query is at least 2 characters long. 
 * Clears search results when the query is shorter than 2 characters.
 * 
 * @returns void
 */
function onSearchInput() {
  if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
  const query = searchQuery.value.trim();
  if (query.length < 2) {
    isSearching.value = false;
    searchFolders.value = [];
    searchFiles.value = [];
    return;
  }
  searchDebounceTimer = setTimeout(() => performSearch(query), 300);
}

/**
 * Searches for folders and files matching the query across the entire S3 bucket. 
 * 
 * @param query Object file or folder to search for
 */
async function performSearch(query: string) {
  isSearching.value = true;
  loading.value = true;
  error.value = '';
  try {
    const result = await apiSearch(query);
    searchFolders.value = result.folders;
    searchFiles.value = result.files;
  } catch (err: any) {
    error.value = err.message || 'Search failed';
  } finally {
    loading.value = false;
  }
}

/**
 * Clear all search state and results
 */
function clearSearch() {
  searchQuery.value = '';
  isSearching.value = false;
  searchFolders.value = [];
  searchFiles.value = [];
  if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
}

/**
 * Requests a signed URL and plays the file. Sends to an active Chromecast session if one is connected, otherwise defaults to local browser playback.
 * Pass cast=true to initiate a new Cast session for this file.
 * 
 * @param file The media file to play, containing at least a 'key' and 'name'
 * @param cast Whether to attempt casting to a device (defaults to false)
 */
async function playFile(file: { key: string; name: string }, cast = false) {
  loading.value = true;
  try {
    const url = await apiGetSignedUrl(file.key);
    const shouldCast = cast || (castAvailable.value && castState.value === 'CONNECTED');

    // If casting is requested and a device is available, send the media to the Cast session
    if (shouldCast && castAvailable.value) {
      const contentType = castGetContentType(file.name);
      await castMedia(url, file.name, contentType);
    
    // Otherwise, play the media locally in the browser
    } else {
      playLocally(url, file.name);
    }
  } catch (err: any) {
    error.value = err.message || 'Failed to play';
  } finally {
    loading.value = false;
  }
}

/** Opens the inline HTML5 audio/video player for local playback. */
/**
 * Opens the inline HTML5 audio/video player for local playback
 * 
 * @param url  The signed URL of the media file to play
 * @param name The display name of the media file
 */
function playLocally(url: string, name: string) {
  playbackUrl.value = url;
  playbackTitle.value = name;
  playbackIsVideo.value = castIsVideo(name);
}

/** 
 * Fetches folder and file listings from the API for the given S3 prefix. 
 * 
 * @param prefix The S3 prefix to browse (e.g. 'movies/action/')
 */
async function load(prefix: string) {
  loading.value = true;
  error.value = '';
  try {
    const result = await apiBrowse(prefix);
    folders.value = result.folders;
    files.value = result.files;
    currentPrefix.value = prefix;
  } catch (err: any) {
    error.value = err.message || 'Failed to load';
  } finally {
    loading.value = false;
  }
}

/**
 * Extracts the S3 prefix from the current route parameters. Handles both string
 */
function prefixFromRoute(): string {
  const raw = route.params.prefix;
  if (!raw) return '';
  return Array.isArray(raw) ? raw.join('/') + '/' : raw + '/';
}

// Watch for changes in the route prefix parameter to load new folder contents
watch(() => route.params.prefix, () => {
  load(prefixFromRoute());
});

// Initial load based on route prefix (will typically be empty for the root path)
onMounted(() => load(prefixFromRoute()));
</script>

<style scoped>
.browser {
  max-width: 800px;
  margin: 0 auto;
  padding: 1rem;
}

.toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 1rem;
}

.toolbar h1 {
  font-size: 1.25rem;
  margin: 0;
}

.toolbar-right {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.logout-btn {
  background: none;
  border: 1px solid #555;
  color: #ccc;
  padding: 0.4rem 0.75rem;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.875rem;
}

.logout-btn:hover {
  background: rgba(255, 255, 255, 0.1);
}

.search-bar {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 1rem;
  position: relative;
}

.search-input {
  flex: 1;
  padding: 0.5rem 2rem 0.5rem 0.75rem;
  border: 1px solid #444;
  border-radius: 6px;
  background: #2a2a2a;
  color: #eee;
  font-size: 0.875rem;
  outline: none;
}

.search-input:focus {
  border-color: #4a9eff;
}

.search-input::placeholder {
  color: #777;
}

.search-clear {
  position: absolute;
  right: 0.5rem;
  background: none;
  border: none;
  color: #888;
  cursor: pointer;
  font-size: 1rem;
  padding: 0.25rem;
}

.search-clear:hover {
  color: #ccc;
}

.breadcrumb {
  display: flex;
  align-items: center;
  gap: 0.25rem;
  margin-bottom: 1rem;
  flex-wrap: wrap;
}

.breadcrumb button {
  background: none;
  border: none;
  color: #4a9eff;
  cursor: pointer;
  padding: 0.25rem 0.4rem;
  border-radius: 4px;
  font-size: 0.875rem;
}

.breadcrumb button:hover {
  background: rgba(74, 158, 255, 0.15);
}

.sep {
  color: #666;
  font-size: 0.875rem;
}

.loading-state {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  justify-content: center;
  padding: 3rem;
  color: #aaa;
}

.error-state {
  text-align: center;
  padding: 2rem;
  color: #ff8a8a;
}

.error-state button {
  margin-top: 1rem;
  background: #333;
  border: 1px solid #555;
  color: #ccc;
  padding: 0.5rem 1rem;
  border-radius: 6px;
  cursor: pointer;
}

.file-list {
  display: flex;
  flex-direction: column;
}

.item {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.75rem;
  border-radius: 6px;
  cursor: pointer;
}

.item:hover {
  background: rgba(255, 255, 255, 0.05);
}

.icon {
  flex-shrink: 0;
}

.name {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.size {
  color: #888;
  font-size: 0.8rem;
  white-space: nowrap;
}

.cast-file-btn {
  background: none;
  border: 1px solid #555;
  border-radius: 4px;
  cursor: pointer;
  padding: 0.2rem 0.4rem;
  font-size: 0.85rem;
  flex-shrink: 0;
}

.cast-file-btn:hover {
  background: rgba(255, 255, 255, 0.1);
}

.empty {
  text-align: center;
  padding: 3rem;
  color: #666;
}

.player {
  position: fixed;
  bottom: 0;
  left: 0;
  right: 0;
  background: #1a1a1a;
  border-top: 1px solid #333;
  padding: 0.75rem;
}

.player-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 0.5rem;
}

.player-title {
  font-size: 0.875rem;
  color: #ccc;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.close-btn {
  background: none;
  border: none;
  color: #888;
  cursor: pointer;
  font-size: 1.25rem;
  padding: 0.25rem;
}

.media-player {
  width: 100%;
  max-height: 300px;
}
</style>
