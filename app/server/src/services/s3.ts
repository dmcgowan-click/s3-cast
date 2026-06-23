import { S3Client, ListObjectsV2Command } from '@aws-sdk/client-s3';

const client = new S3Client({});

const SUPPORTED_EXTENSIONS = ['.mp4', '.webm', '.mp3', '.flac', '.aac', '.ogg'];
const ALLOWED_PREFIXES = ['Music/', 'Video/'];
const SEARCH_MAX_RESULTS = 50;

/** Response shape for the media browse endpoint. */
interface BrowseResult {
  folders: string[];
  files: { key: string; name: string; size: number; lastModified: string }[];
}

/** Returns true if the S3 object key ends with a supported media extension. */
function isSupportedFile(key: string): boolean {
  const lower = key.toLowerCase();
  return SUPPORTED_EXTENSIONS.some((ext) => lower.endsWith(ext));
}

/** Returns true if the prefix falls within the allowed top-level directories (Music/, Video/). */
function isAllowedPrefix(prefix: string): boolean {
  return ALLOWED_PREFIXES.some((allowed) => prefix.startsWith(allowed));
}

/**
 * Lists folders and media files in the S3 media bucket under the given prefix.
 * Sanitises the prefix to prevent path traversal, restricts access to allowed
 * top-level directories, and filters results to supported file extensions.
 */
export async function browseMedia(prefix: string): Promise<BrowseResult> {
  const bucket = process.env.MEDIA_BUCKET;
  if (!bucket) throw new Error('MEDIA_BUCKET not set');

  // Validate prefix to prevent path traversal
  const decoded = decodeURIComponent(prefix);
  const normalised = decoded.replace(/\\/g, '/').replace(/\/\//g, '/');
  if (normalised.includes('..')) {
    throw new Error('Access denied: prefix outside allowed paths');
  }
  if (!isAllowedPrefix(normalised)) {
    // If no prefix, return the top-level allowed prefixes as folders
    if (normalised === '') {
      return { folders: ALLOWED_PREFIXES, files: [] };
    }
    throw new Error('Access denied: prefix outside allowed paths');
  }

  const result = await client.send(
    new ListObjectsV2Command({
      Bucket: bucket,
      Prefix: normalised,
      Delimiter: '/',
    }),
  );

  const folders = (result.CommonPrefixes || [])
    .map((cp) => cp.Prefix!)
    .filter(Boolean);

  const files = (result.Contents || [])
    .filter((obj) => obj.Key && isSupportedFile(obj.Key))
    .map((obj) => ({
      key: obj.Key!,
      name: obj.Key!.split('/').pop()!,
      size: obj.Size || 0,
      lastModified: obj.LastModified?.toISOString() || '',
    }));

  return { folders, files };
}

/** Response shape for the media search endpoint. */
interface SearchResult {
  folders: string[];
  files: { key: string; name: string; size: number; lastModified: string }[];
}

/**
 * Searches for folders and files whose names contain the query string
 * (case-insensitive) across all allowed S3 prefixes. Paginates through
 * S3 results and caps output at SEARCH_MAX_RESULTS total items.
 */
export async function searchMedia(query: string): Promise<SearchResult> {
  const bucket = process.env.MEDIA_BUCKET;
  if (!bucket) throw new Error('MEDIA_BUCKET not set');

  const lowerQuery = query.toLowerCase();
  const matchedFolders = new Set<string>();
  const matchedFiles: SearchResult['files'] = [];

  for (const allowedPrefix of ALLOWED_PREFIXES) {
    let continuationToken: string | undefined;

    do {
      const result = await client.send(
        new ListObjectsV2Command({
          Bucket: bucket,
          Prefix: allowedPrefix,
          ContinuationToken: continuationToken,
        }),
      );

      for (const obj of result.Contents || []) {
        if (!obj.Key) continue;
        const segments = obj.Key.split('/');

        // Check folder segments for matches (skip first allowed prefix segment)
        for (let i = 1; i < segments.length - 1; i++) {
          if (segments[i].toLowerCase().includes(lowerQuery)) {
            const folderPrefix = segments.slice(0, i + 1).join('/') + '/';
            matchedFolders.add(folderPrefix);
          }
        }

        // Check file name for match
        const fileName = segments[segments.length - 1];
        if (fileName && isSupportedFile(obj.Key) && fileName.toLowerCase().includes(lowerQuery)) {
          matchedFiles.push({
            key: obj.Key,
            name: fileName,
            size: obj.Size || 0,
            lastModified: obj.LastModified?.toISOString() || '',
          });
        }

        if (matchedFolders.size + matchedFiles.length >= SEARCH_MAX_RESULTS) break;
      }

      if (matchedFolders.size + matchedFiles.length >= SEARCH_MAX_RESULTS) break;

      continuationToken = result.NextContinuationToken;
    } while (continuationToken);

    if (matchedFolders.size + matchedFiles.length >= SEARCH_MAX_RESULTS) break;
  }

  return {
    folders: [...matchedFolders].slice(0, SEARCH_MAX_RESULTS),
    files: matchedFiles.slice(0, SEARCH_MAX_RESULTS),
  };
}
