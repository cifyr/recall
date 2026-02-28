import { env } from './env.ts';

export function buildSegmentStoragePath(
  userId: string,
  sessionId: string,
  segmentIndex: number,
  fileExt = 'm4a',
): string {
  return `u/${userId}/s/${sessionId}/segments/${segmentIndex}.${fileExt}`;
}

export function segmentPublicUploadUrl(signedPath: string): string {
  if (signedPath.startsWith('http://') || signedPath.startsWith('https://')) {
    return signedPath;
  }
  return `${env.supabaseUrl}/storage/v1${signedPath}`;
}
