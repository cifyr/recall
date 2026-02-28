import { AppError } from './errors.ts';

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new AppError('missing_env', `Missing environment variable: ${name}`, 500);
  }
  return value;
}

export const env = {
  supabaseUrl: required('SUPABASE_URL'),
  supabaseAnonKey: required('SUPABASE_ANON_KEY'),
  supabaseServiceRoleKey: required('SUPABASE_SERVICE_ROLE_KEY'),
  openAiApiKey: Deno.env.get('OPENAI_API_KEY') ?? '',
  internalJobSecret: Deno.env.get('INTERNAL_JOB_SECRET') ?? '',
  appBaseUrl: Deno.env.get('APP_BASE_URL') ?? Deno.env.get('SUPABASE_URL') ?? '',
  audioBucket: Deno.env.get('AUDIO_BUCKET') ?? 'conversation-audio',
  defaultTranscriptionModel: Deno.env.get('OPENAI_TRANSCRIPTION_MODEL') ?? 'whisper-1',
  defaultSummaryModel: Deno.env.get('OPENAI_SUMMARY_MODEL') ?? 'gpt-4o-mini',
  defaultQaModel: Deno.env.get('OPENAI_QA_MODEL') ?? 'gpt-4o-mini',
};
