import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, parseJson } from '../_shared/request.ts';
import { getInternalSecretForInternalCalls, requireInternalSecret } from '../_shared/auth.ts';
import { requireUuid } from '../_shared/validation.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { AppError } from '../_shared/errors.ts';
import { env } from '../_shared/env.ts';
import { transcribeAudio } from '../_shared/openai.ts';
import { insertFailure, insertStageTransition } from '../_shared/db.ts';
import { success } from '../_shared/response.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('transcribe-session', context.requestId, async () => {
    assertMethod(request, 'POST');
    await requireInternalSecret(request);
    const body = await parseJson<Record<string, unknown>>(request);
    const internalSecret = await getInternalSecretForInternalCalls();
    const sessionId = requireUuid(body.session_id, 'session_id');
    const model = typeof body.transcription_model === 'string'
      ? body.transcription_model
      : env.defaultTranscriptionModel;
    const serviceClient = createServiceClient();

    const { data: session, error: sessionError } = await serviceClient
      .from('conversation_sessions')
      .select('*')
      .eq('id', sessionId)
      .maybeSingle();

    if (sessionError) {
      throw new AppError('session_lookup_failed', sessionError.message, 500);
    }

    if (!session) {
      throw new AppError('session_not_found', 'Session not found', 404);
    }

    try {
      await serviceClient
        .from('conversation_sessions')
        .update({
          status: 'transcribing',
          latest_error_code: null,
          latest_error_message: null,
          request_id: context.requestId,
        })
        .eq('id', sessionId);

      await insertStageTransition({
        sessionId,
        userId: session.user_id,
        fromStatus: session.status,
        toStatus: 'transcribing',
        reason: 'pipeline_transcribe_start',
        requestId: context.requestId,
        correlationId: context.correlation_id ?? context.correlationId,
        actorPlatform: 'edge',
      });

      const { data: quota, error: quotaError } = await serviceClient
        .from('user_usage_quotas')
        .select('*')
        .eq('user_id', session.user_id)
        .maybeSingle();
      if (quotaError) {
        throw new AppError('quota_lookup_failed', quotaError.message, 500);
      }

      const today = new Date().toISOString().slice(0, 10);
      const { data: usage, error: usageError } = await serviceClient
        .from('user_daily_audio_usage')
        .select('*')
        .eq('usage_date', today)
        .eq('user_id', session.user_id)
        .maybeSingle();
      if (usageError) {
        throw new AppError('quota_lookup_failed', usageError.message, 500);
      }

      const { data: segments, error: segmentsError } = await serviceClient
        .from('conversation_segments')
        .select('*')
        .eq('session_id', sessionId)
        .eq('user_id', session.user_id)
        .eq('upload_status', 'uploaded')
        .order('segment_index', { ascending: true });

      if (segmentsError) {
        throw new AppError('audio_not_found', segmentsError.message, 500);
      }

      if (!segments || segments.length === 0) {
        throw new AppError('audio_not_found', 'No uploaded segments found', 404);
      }

      const totalAudioSeconds = Math.ceil(
        segments.reduce((acc, segment) => acc + (segment.duration_ms ?? 0), 0) / 1000,
      );
      const currentValue = usage?.transcribed_audio_seconds ?? 0;
      const limitValue = quota?.daily_audio_seconds_limit ?? 3600;
      if ((quota?.is_enabled ?? true) && currentValue + totalAudioSeconds > limitValue) {
        await serviceClient.from('quota_decisions').insert({
          user_id: session.user_id,
          action_key: 'transcribe_session',
          request_id: context.requestId,
          allowed: false,
          limit_value: limitValue,
          current_value: currentValue,
          window_start: today,
        });
        throw new AppError('rate_limit_exceeded', 'Daily transcription quota exceeded', 429);
      }

      const transcriptSegments: Array<Record<string, unknown>> = [];
      for (const segment of segments) {
        const { data: blob, error: downloadError } = await serviceClient.storage
          .from(env.audioBucket)
          .download(segment.storage_path);

        if (downloadError || !blob) {
          throw new AppError('audio_not_found', downloadError?.message ?? 'Audio segment missing', 404);
        }

        const fileName = segment.storage_path.split('/').pop() ?? `${segment.segment_index}.m4a`;
        const file = new File([blob], fileName, { type: 'audio/m4a' });
        const transcription = await transcribeAudio({
          file,
          fileName,
          language: 'en',
          model,
        });

        transcriptSegments.push({
          segment_index: segment.segment_index,
          storage_path: segment.storage_path,
          duration_ms: segment.duration_ms,
          transcript_text: transcription.text,
        });
      }

      const transcriptText = transcriptSegments
        .map((segment) => String(segment.transcript_text))
        .join('\n\n')
        .trim();

      const { error: transcriptError } = await serviceClient.from('conversation_transcripts').upsert({
        session_id: sessionId,
        user_id: session.user_id,
        transcript_text: transcriptText,
        segments_json: transcriptSegments,
        language: 'en',
        model,
        audio_seconds: totalAudioSeconds,
        request_id: context.requestId,
        correlation_id: context.correlation_id ?? context.correlationId,
      }, {
        onConflict: 'session_id',
      });

      if (transcriptError) {
        throw new AppError('transcription_upstream_error', transcriptError.message, 500);
      }

      await serviceClient.from('user_daily_audio_usage').upsert({
        usage_date: today,
        user_id: session.user_id,
        transcribed_audio_seconds: currentValue + totalAudioSeconds,
        updated_at: new Date().toISOString(),
      }, {
        onConflict: 'usage_date,user_id',
      });

      await serviceClient.from('quota_decisions').insert({
        user_id: session.user_id,
        action_key: 'transcribe_session',
        request_id: context.requestId,
        allowed: true,
        limit_value: limitValue,
        current_value: currentValue + totalAudioSeconds,
        window_start: today,
      });

      await serviceClient.from('ai_model_calls').insert({
        user_id: session.user_id,
        session_id: sessionId,
        stage: 'transcribe',
        provider: 'openai',
        model,
        audio_seconds: totalAudioSeconds,
        request_id: context.requestId,
        correlation_id: context.correlation_id ?? context.correlationId,
      });

      await serviceClient
        .from('conversation_sessions')
        .update({
          status: 'transcribed',
          latest_error_code: null,
          latest_error_message: null,
          request_id: context.requestId,
        })
        .eq('id', sessionId);

      await insertStageTransition({
        sessionId,
        userId: session.user_id,
        fromStatus: 'transcribing',
        toStatus: 'transcribed',
        reason: 'pipeline_transcribe_success',
        requestId: context.requestId,
        correlationId: context.correlation_id ?? context.correlationId,
        actorPlatform: 'edge',
      });

      for (const promptName of ['say_prompt_default', 'say_prompt_action_items']) {
        const response = await fetch(`${env.supabaseUrl}/functions/v1/summarize-session`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'x-internal-job-secret': internalSecret,
            'x-request-id': crypto.randomUUID(),
            'x-correlation-id': context.correlationId ?? session.correlation_id ?? context.requestId,
            'x-platform': 'edge',
          },
          body: JSON.stringify({
            session_id: sessionId,
            summary_prompt_name: promptName,
          }),
        });

        if (!response.ok) {
          const payload = await response.text();
          throw new AppError('summary_upstream_error', payload || `Summary failed for ${promptName}`, 502);
        }
      }

      return {
        response: success({
          session_id: sessionId,
          status: 'transcribed',
        }, context.requestId),
        userId: session.user_id,
        correlationId: context.correlationId ?? session.correlation_id,
      };
    } catch (error) {
      const appError = error instanceof AppError ? error : new AppError('transcription_upstream_error', 'Transcription failed', 500);
      await insertFailure({
        sessionId,
        userId: session.user_id,
        stage: 'transcribe',
        errorCode: appError.code,
        errorMessage: appError.message,
        requestId: context.requestId,
        correlationId: context.correlationId ?? session.correlation_id,
      });
      throw appError;
    }
  });
});
