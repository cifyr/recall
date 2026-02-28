import { assertMethod, withErrorHandling } from '../_shared/http.ts';
import { buildRequestContext, parseJson } from '../_shared/request.ts';
import { requireUser } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/clients.ts';
import { AppError } from '../_shared/errors.ts';
import { success } from '../_shared/response.ts';

Deno.serve(async (request) => {
  const context = buildRequestContext(request);

  return await withErrorHandling('health-snapshot', context.requestId, async () => {
    assertMethod(request, 'POST');
    const authUser = await requireUser(request);
    const body = await parseJson<{ device_id?: string }>(request);
    const serviceClient = createServiceClient();

    const todayStart = new Date();
    todayStart.setUTCHours(0, 0, 0, 0);

    const weekStart = new Date();
    weekStart.setUTCDate(weekStart.getUTCDate() - weekStart.getUTCDay());
    weekStart.setUTCHours(0, 0, 0, 0);

    const { data: failures, error: failuresError } = await serviceClient
      .from('conversation_failures')
      .select('stage, error_code, error_message, created_at')
      .eq('user_id', authUser.id)
      .order('created_at', { ascending: false })
      .limit(5);
    if (failuresError) {
      throw new AppError('health_snapshot_failed', failuresError.message, 500);
    }

    const { data: transcripts, error: transcriptsError } = await serviceClient
      .from('conversation_transcripts')
      .select('audio_seconds')
      .eq('user_id', authUser.id)
      .gte('created_at', todayStart.toISOString());
    if (transcriptsError) {
      throw new AppError('health_snapshot_failed', transcriptsError.message, 500);
    }

    const { data: calls, error: callsError } = await serviceClient
      .from('ai_model_calls')
      .select('estimated_cost_usd')
      .eq('user_id', authUser.id)
      .gte('created_at', weekStart.toISOString());
    if (callsError) {
      throw new AppError('health_snapshot_failed', callsError.message, 500);
    }

    const { data: rules, error: rulesError } = await serviceClient
      .from('cost_budget_rules')
      .select('scope_type, scope_id, cap_usd')
      .eq('is_enabled', true);
    if (rulesError) {
      throw new AppError('health_snapshot_failed', rulesError.message, 500);
    }

    const dailyAudioUsageSeconds = Math.round(
      (transcripts ?? []).reduce((sum, transcript) => sum + Number(transcript.audio_seconds ?? 0), 0),
    );
    const weeklySpendUsd = (calls ?? []).reduce((sum, call) => sum + Number(call.estimated_cost_usd ?? 0), 0);
    const weeklySpendPercent = Math.max(
      0,
      ...((rules ?? [])
        .filter((rule) => rule.scope_type === 'global' || (rule.scope_type === 'user' && rule.scope_id === authUser.id))
        .map((rule) => {
          const capUsd = Number(rule.cap_usd ?? 0);
          return capUsd > 0 ? (weeklySpendUsd / capUsd) * 100 : 0;
        })),
    );

    const lastSyncErrors = (failures ?? []).map((failure) => {
      const base = `${failure.stage}: ${failure.error_code}`;
      return failure.error_message ? `${base} (${failure.error_message})` : base;
    });

    return {
      response: success({
        current_device_id: body.device_id ?? context.deviceId,
        last_sync_errors: lastSyncErrors,
        weekly_spend_percent: weeklySpendPercent,
        daily_audio_usage_seconds: dailyAudioUsageSeconds,
      }, context.requestId),
      userId: authUser.id,
      correlationId: context.correlationId,
    };
  });
});
