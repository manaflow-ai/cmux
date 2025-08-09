export interface AIProvider {
  name: string;
  envVar: string;
  checkAvailable: () => Promise<boolean>;
  cheapModel: string;
  callApi: (prompt: string, apiKey: string) => Promise<string>;
}

const OPENAI_PROVIDER: AIProvider = {
  name: "openai",
  envVar: "OPENAI_API_KEY",
  cheapModel: "gpt-4o-mini",
  checkAvailable: async () => {
    return !!(process.env.OPENAI_API_KEY?.trim());
  },
  callApi: async (prompt: string, apiKey: string) => {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages: [{ role: "user", content: prompt }],
        max_tokens: 50,
        temperature: 0.3,
      }),
    });

    if (!response.ok) {
      throw new Error(`OpenAI API error: ${response.statusText}`);
    }

    const data = await response.json();
    return data.choices[0].message.content.trim();
  },
};

const ANTHROPIC_PROVIDER: AIProvider = {
  name: "anthropic",
  envVar: "ANTHROPIC_API_KEY",
  cheapModel: "claude-3-5-haiku-20241022",
  checkAvailable: async () => {
    return !!(process.env.ANTHROPIC_API_KEY?.trim());
  },
  callApi: async (prompt: string, apiKey: string) => {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-3-5-haiku-20241022",
        max_tokens: 50,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!response.ok) {
      throw new Error(`Anthropic API error: ${response.statusText}`);
    }

    const data = await response.json();
    return data.content[0].text.trim();
  },
};

const GEMINI_PROVIDER: AIProvider = {
  name: "gemini",
  envVar: "GEMINI_API_KEY",
  cheapModel: "gemini-2.0-flash-exp",
  checkAvailable: async () => {
    return !!(process.env.GEMINI_API_KEY?.trim());
  },
  callApi: async (prompt: string, apiKey: string) => {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=${apiKey}`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: {
            maxOutputTokens: 50,
            temperature: 0.3,
          },
        }),
      }
    );

    if (!response.ok) {
      throw new Error(`Gemini API error: ${response.statusText}`);
    }

    const data = await response.json();
    return data.candidates[0].content.parts[0].text.trim();
  },
};

const ALL_PROVIDERS = [OPENAI_PROVIDER, ANTHROPIC_PROVIDER, GEMINI_PROVIDER];

export interface ProviderAvailability {
  provider: AIProvider;
  isAvailable: boolean;
  apiKey?: string;
}

/**
 * Detect which AI providers are available by checking environment variables
 */
export async function detectAvailableProviders(): Promise<ProviderAvailability[]> {
  const results: ProviderAvailability[] = [];

  for (const provider of ALL_PROVIDERS) {
    const apiKey = process.env[provider.envVar]?.trim();
    const isAvailable = await provider.checkAvailable();
    
    results.push({
      provider,
      isAvailable,
      apiKey: isAvailable ? apiKey : undefined,
    });
  }

  return results;
}

/**
 * Get the first available AI provider, prioritizing based on reliability and cost
 */
export async function getPreferredProvider(): Promise<ProviderAvailability | null> {
  const available = await detectAvailableProviders();
  
  // Priority order: OpenAI (most reliable), Anthropic, Gemini
  const priorityOrder = ["openai", "anthropic", "gemini"];
  
  for (const providerName of priorityOrder) {
    const provider = available.find(p => p.provider.name === providerName && p.isAvailable);
    if (provider) {
      return provider;
    }
  }

  return null;
}

/**
 * Generate a descriptive folder/branch name using AI
 */
export async function generateAIName(
  taskDescription: string,
  type: "folder" | "branch",
  prefix?: string
): Promise<string> {
  const provider = await getPreferredProvider();
  
  if (!provider || !provider.apiKey) {
    // Fallback to timestamp-based naming
    const timestamp = Date.now();
    const fallbackName = type === "branch" ? `cmux-${timestamp}` : `cmux-${timestamp}`;
    return prefix ? `${prefix}${fallbackName}` : fallbackName;
  }

  const typeWord = type === "folder" ? "directory" : "branch";
  const prompt = `Generate a short, descriptive ${typeWord} name (max 40 chars, lowercase, use hyphens) for this coding task: "${taskDescription.substring(0, 200)}". Return only the name, no explanation.`;

  try {
    let generatedName = await provider.provider.callApi(prompt, provider.apiKey);
    
    // Clean up the generated name
    generatedName = generatedName
      .toLowerCase()
      .replace(/[^a-z0-9\s-]/g, '') // Remove special chars except spaces and hyphens
      .replace(/\s+/g, '-') // Replace spaces with hyphens
      .replace(/--+/g, '-') // Replace multiple hyphens with single
      .replace(/^-+|-+$/g, '') // Remove leading/trailing hyphens
      .substring(0, 40); // Limit length

    // Ensure we have a valid name
    if (!generatedName || generatedName.length < 3) {
      throw new Error("Generated name too short");
    }

    // Add prefix if provided
    const finalName = prefix ? `${prefix}${generatedName}` : generatedName;
    
    // Ensure uniqueness by adding timestamp suffix if needed
    const timestamp = Date.now();
    return `${finalName}-${timestamp.toString().slice(-6)}`;

  } catch (error) {
    console.warn(`Failed to generate AI name: ${error}`);
    // Fallback to timestamp-based naming
    const timestamp = Date.now();
    const fallbackName = type === "branch" ? `cmux-${timestamp}` : `cmux-${timestamp}`;
    return prefix ? `${prefix}${fallbackName}` : fallbackName;
  }
}