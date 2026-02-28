import OpenAI from 'npm:openai@4';
import { env } from './env.ts';
import { AppError } from './errors.ts';
import { resolveSecretValue } from './secrets.ts';

type Usage = {
  input_tokens?: number;
  output_tokens?: number;
};

export async function transcribeAudio(input: {
  file: File;
  fileName: string;
  language: string;
  model?: string;
}): Promise<{ text: string; model: string; usage?: Usage }> {
  if (!(await hasConfiguredOpenAIKey())) {
    return {
      text: `[OpenAI key not configured. Placeholder transcript generated for ${input.fileName}.]`,
      model: 'placeholder-transcript',
    };
  }

  try {
    const client = await createOpenAIClient();
    const response = await client.audio.transcriptions.create({
      file: input.file,
      model: input.model ?? env.defaultTranscriptionModel,
      language: input.language,
    });

    return {
      text: response.text,
      model: input.model ?? env.defaultTranscriptionModel,
    };
  } catch (error) {
    if (shouldUsePlaceholderFallback(error)) {
      return {
        text: `[OpenAI unavailable. Placeholder transcript generated for ${input.fileName}.]`,
        model: 'placeholder-transcript',
      };
    }
    throw error;
  }
}

export async function summarizeText(input: {
  transcript: string;
  notes: string;
  prompt: string;
  model?: string;
}): Promise<{ text: string; model: string; usage?: Usage }> {
  if (!(await hasConfiguredOpenAIKey())) {
    const excerpt = input.transcript.trim().slice(0, 280);
    const notesSuffix = input.notes.trim().length === 0 ? '' : ` Notes: ${input.notes.trim().slice(0, 180)}`;
    return {
      text: `[OpenAI key not configured. Placeholder summary.] ${excerpt}${notesSuffix}`,
      model: 'placeholder-summary',
    };
  }

  try {
    const client = await createOpenAIClient();
    const response = await client.responses.create({
      model: input.model ?? env.defaultSummaryModel,
      temperature: 0.2,
      input: [
        {
          role: 'system',
          content: input.prompt,
        },
        {
          role: 'user',
          content: `Transcript:\n${input.transcript}\n\nNotes:\n${input.notes || 'None'}`,
        },
      ],
    });

    return {
      text: readOutputText(response),
      model: input.model ?? env.defaultSummaryModel,
      usage: response.usage
        ? {
          input_tokens: response.usage.input_tokens,
          output_tokens: response.usage.output_tokens,
        }
        : undefined,
    };
  } catch (error) {
    if (shouldUsePlaceholderFallback(error)) {
      const excerpt = input.transcript.trim().slice(0, 280);
      const notesSuffix = input.notes.trim().length === 0 ? '' : ` Notes: ${input.notes.trim().slice(0, 180)}`;
      return {
        text: `[OpenAI unavailable. Placeholder summary.] ${excerpt}${notesSuffix}`,
        model: 'placeholder-summary',
      };
    }
    throw error;
  }
}

export async function answerQuestion(input: {
  transcript: string;
  summaries: string;
  notes: string;
  question: string;
  prompt: string;
  model?: string;
}): Promise<{ text: string; model: string; usage?: Usage }> {
  if (!(await hasConfiguredOpenAIKey())) {
    return {
      text: `OpenAI key not configured. Placeholder answer only. Question: ${input.question}`,
      model: 'placeholder-qa',
    };
  }

  try {
    const client = await createOpenAIClient();
    const response = await client.responses.create({
      model: input.model ?? env.defaultQaModel,
      temperature: 0,
      input: [
        {
          role: 'system',
          content: input.prompt,
        },
        {
          role: 'user',
          content:
            `Transcript:\n${input.transcript}\n\nSummaries:\n${input.summaries}\n\nNotes:\n${input.notes || 'None'}\n\nQuestion:\n${input.question}`,
        },
      ],
    });

    return {
      text: readOutputText(response),
      model: input.model ?? env.defaultQaModel,
      usage: response.usage
        ? {
          input_tokens: response.usage.input_tokens,
          output_tokens: response.usage.output_tokens,
        }
        : undefined,
    };
  } catch (error) {
    if (shouldUsePlaceholderFallback(error)) {
      return {
        text: `OpenAI unavailable. Placeholder answer only. Question: ${input.question}`,
        model: 'placeholder-qa',
      };
    }
    throw error;
  }
}

function readOutputText(response: OpenAI.Responses.Response): string {
  const text = response.output_text?.trim();
  if (!text) {
    throw new AppError('empty_model_output', 'OpenAI returned empty output', 502);
  }
  return text;
}

async function createOpenAIClient(): Promise<OpenAI> {
  const apiKey = await resolveSecretValue({
    envValue: env.openAiApiKey,
    vaultName: 'openai_api_key',
    errorCode: 'missing_openai_key',
    errorMessage: 'OpenAI API key is not configured',
  });

  return new OpenAI({ apiKey });
}

async function hasConfiguredOpenAIKey(): Promise<boolean> {
  try {
    await resolveSecretValue({
      envValue: env.openAiApiKey,
      vaultName: 'openai_api_key',
      errorCode: 'missing_openai_key',
      errorMessage: 'OpenAI API key is not configured',
    });
    return true;
  } catch {
    return false;
  }
}

function shouldUsePlaceholderFallback(error: unknown): boolean {
  if (!error || typeof error !== 'object') {
    return false;
  }

  const status = 'status' in error ? (error as { status?: number }).status : undefined;
  if (status === 429) {
    return true;
  }

  const message = error instanceof Error ? error.message.toLowerCase() : '';
  return message.includes('quota')
    || message.includes('billing')
    || message.includes('rate limit')
    || message.includes('429');
}
