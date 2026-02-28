import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, parseJson } from '../_shared/request.ts';
import { requireInternalSecret } from '../_shared/auth.ts';
import { requireString, requireUuid } from '../_shared/validation.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { AppError } from '../_shared/errors.ts';
import { getPromptTemplate } from '../_shared/prompts.ts';
import { summarizeText } from '../_shared/openai.ts';
import { env } from '../_shared/env.ts';
import { insertFailure, insertStageTransition } from '../_shared/db.ts';
import { success } from '../_shared/response.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('summarize-session', context.requestId, async () => {
    assertMethod(request, 'POST');
    await requireInternalSecret(request);
    const body = await parseJson<Record<string, unknown>>(request);
    const sessionId = requireUuid(body.session_id, 'session_id');
    const promptName = requireString(body.summary_prompt_name ?? 'say_prompt_default', 'summary_prompt_name', 100);
    const requestedVersion = typeof body.summary_prompt_version === 'number'
      ? body.summary_prompt_version
      : undefined;
    const model = typeof body.summary_model === 'string' ? body.summary_model : env.defaultSummaryModel;
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
      const { data: transcript, error: transcriptError } = await serviceClient
        .from('conversation_transcripts')
        .select('*')
        .eq('session_id', sessionId)
        .maybeSingle();
      if (transcriptError) {
        throw new AppError('transcript_missing', transcriptError.message, 500);
      }
      if (!transcript) {
        throw new AppError('transcript_missing', 'Transcript does not exist', 404);
      }

      const { data: notes } = await serviceClient
        .from('conversation_notes')
        .select('note_text')
        .eq('session_id', sessionId)
        .eq('user_id', session.user_id)
        .maybeSingle();

      const promptTemplate = await getPromptTemplate(promptName, requestedVersion);
      await serviceClient
        .from('conversation_sessions')
        .update({
          status: 'summarizing',
          request_id: context.requestId,
        })
        .eq('id', sessionId);

      await insertStageTransition({
        sessionId,
        userId: session.user_id,
        fromStatus: session.status,
        toStatus: 'summarizing',
        reason: `summary_${promptName}_start`,
        requestId: context.requestId,
        correlationId: context.correlationId ?? session.correlation_id,
        actorPlatform: 'edge',
      });

      const summary = await summarizeText({
        transcript: transcript.transcript_text,
        notes: notes?.note_text ?? '',
        prompt: promptTemplate.template_text,
        model,
      });

      const { error: summaryError } = await serviceClient.from('conversation_summaries').upsert({
        session_id: sessionId,
        user_id: session.user_id,
        summary_prompt_name: promptTemplate.name,
        summary_prompt_version: promptTemplate.version,
        summary_text: summary.text,
        model: summary.model,
        tokens_in: summary.usage?.input_tokens ?? null,
        tokens_out: summary.usage?.output_tokens ?? null,
        request_id: context.requestId,
        correlation_id: context.correlation_id ?? context.correlationId,
      }, {
        onConflict: 'session_id,summary_prompt_name,summary_prompt_version',
      });
      if (summaryError) {
        throw new AppError('summary_upstream_error', summaryError.message, 500);
      }

      await serviceClient.from('ai_model_calls').insert({
        user_id: session.user_id,
        session_id: sessionId,
        stage: 'summarize',
        provider: 'openai',
        model: summary.model,
        prompt_template_name: promptTemplate.name,
        prompt_template_version: promptTemplate.version,
        tokens_in: summary.usage?.input_tokens ?? null,
        tokens_out: summary.usage?.output_tokens ?? null,
        request_id: context.requestId,
        correlation_id: context.correlation_id ?? context.correlationId,
      });

      const { data: allSummaries, error: countError } = await serviceClient
        .from('conversation_summaries')
        .select('summary_prompt_name')
        .eq('session_id', sessionId)
        .in('summary_prompt_name', ['say_prompt_default', 'say_prompt_action_items']);
      if (countError) {
        throw new AppError('summary_lookup_failed', countError.message, 500);
      }

      const finalStatus = (allSummaries?.length ?? 0) >= 2 ? 'summarized' : 'summarizing';
      await serviceClient
        .from('conversation_sessions')
        .update({
          status: finalStatus,
          latest_error_code: null,
          latest_error_message: null,
          request_id: context.requestId,
        })
        .eq('id', sessionId);

      if (finalStatus === 'summarized') {
        await insertStageTransition({
          sessionId,
          userId: session.user_id,
          fromStatus: 'summarizing',
          toStatus: 'summarized',
          reason: 'all_summaries_ready',
          requestId: context.requestId,
          correlationId: context.correlationId ?? session.correlation_id,
          actorPlatform: 'edge',
        });
      }

      return {
        response: success({
          session_id: sessionId,
          status: finalStatus,
          summary_prompt_name: promptTemplate.name,
          summary_prompt_version: promptTemplate.version,
        }, context.requestId),
        userId: session.user_id,
        correlationId: context.correlationId ?? session.correlation_id,
      };
    } catch (error) {
      const appError = error instanceof AppError ? error : new AppError('summary_upstream_error', 'Summary failed', 500);
      await insertFailure({
        sessionId,
        userId: session.user_id,
        stage: 'summarize',
        errorCode: appError.code,
        errorMessage: appError.message,
        requestId: context.requestId,
        correlationId: context.correlationId ?? session.correlation_id,
      });
      throw appError;
    }
  });
});
