// This module is Node.js only - it accesses the filesystem
// Do not import this in browser code

interface NameGenerationConfig {
  prefix?: string;
  maxLength?: number;
  includeTimestamp?: boolean;
}

interface LLMProvider {
  name: string;
  model: string;
  apiKey: string;
  endpoint: string;
}

interface GeneratedNames {
  folderName: string;
  branchName: string;
}

/**
 * Detect which LLM providers are available based on environment variables and config files
 */
export async function detectAvailableLLMProviders(): Promise<LLMProvider[]> {
  const providers: LLMProvider[] = [];

  // Check OpenAI
  const openaiKey = process.env.OPENAI_API_KEY;
  if (openaiKey) {
    providers.push({
      name: "openai",
      model: "gpt-4o-mini", // Cheap model as requested
      apiKey: openaiKey,
      endpoint: "https://api.openai.com/v1/chat/completions",
    });
  }

  // Check Anthropic
  const anthropicKey = process.env.ANTHROPIC_API_KEY;
  if (anthropicKey) {
    providers.push({
      name: "anthropic",
      model: "claude-3-5-haiku-20241022",
      apiKey: anthropicKey,
      endpoint: "https://api.anthropic.com/v1/messages",
    });
  }

  // Check Gemini
  const geminiKey = process.env.GEMINI_API_KEY;
  if (geminiKey) {
    providers.push({
      name: "gemini",
      model: "gemini-2.0-flash-exp", // Using available model instead of gemini-2.5-flash-lite
      apiKey: geminiKey,
      endpoint: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent",
    });
  }

  // Try to read API keys from configuration files
  try {
    const { readFile } = await import("node:fs/promises");
    const { homedir } = await import("node:os");
    
    // Check for OpenAI config in ~/.codex/auth.json
    try {
      const codexAuth = await readFile(`${homedir()}/.codex/auth.json`, "utf-8");
      const authData = JSON.parse(codexAuth);
      if (authData.api_key && !openaiKey) {
        providers.push({
          name: "openai",
          model: "gpt-4o-mini",
          apiKey: authData.api_key,
          endpoint: "https://api.openai.com/v1/chat/completions",
        });
      }
    } catch {
      // Ignore if file doesn't exist
    }

    // Check for Claude credentials
    try {
      const claudeCredentials = await readFile(`${homedir()}/.claude/.credentials.json`, "utf-8");
      const credentials = JSON.parse(claudeCredentials);
      if (credentials.claudeAiOauth && !anthropicKey) {
        // Note: This would require special handling for OAuth vs API key
        // For now, we'll skip OAuth and only use API keys
      }
    } catch {
      // Ignore if file doesn't exist
    }

    // Check for Gemini config in ~/.gemini/settings.json
    try {
      const geminiSettings = await readFile(`${homedir()}/.gemini/settings.json`, "utf-8");
      const settings = JSON.parse(geminiSettings);
      if (settings.apiKey && !geminiKey) {
        providers.push({
          name: "gemini",
          model: "gemini-2.0-flash-exp",
          apiKey: settings.apiKey,
          endpoint: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent",
        });
      }
    } catch {
      // Ignore if file doesn't exist
    }
  } catch (error) {
    console.warn("Error reading LLM configuration files:", error);
  }

  return providers;
}

/**
 * Generate better folder and branch names using the cheapest available LLM
 */
export async function generateBetterNames(
  taskDescription: string,
  config: NameGenerationConfig = {}
): Promise<GeneratedNames> {
  const providers = await detectAvailableLLMProviders();
  
  if (providers.length === 0) {
    // Fallback to the current naming scheme if no providers available
    const timestamp = Date.now();
    const sanitized = sanitizeForFilesystem(taskDescription);
    return {
      folderName: `cmux-${sanitized}-${timestamp}`,
      branchName: `${config.prefix || ""}cmux-${sanitized}-${timestamp}`,
    };
  }

  // Choose the first available provider (prioritize by order: OpenAI, Anthropic, Gemini)
  const provider = providers[0];

  try {
    const prompt = `Generate a concise, descriptive name for a coding task. The task is: "${taskDescription}"

Requirements:
- Maximum ${config.maxLength || 50} characters
- Use lowercase letters, numbers, and hyphens only
- Be descriptive but concise
- No spaces or special characters except hyphens
- Start with a letter or number

Return only the name, nothing else.`;

    let response: string;

    if (provider.name === "openai") {
      response = await callOpenAI(provider, prompt);
    } else if (provider.name === "anthropic") {
      response = await callAnthropic(provider, prompt);
    } else if (provider.name === "gemini") {
      response = await callGemini(provider, prompt);
    } else {
      throw new Error(`Unsupported provider: ${provider.name}`);
    }

    const generatedName = sanitizeForFilesystem(response.trim());
    const timestamp = config.includeTimestamp !== false ? Date.now() : null;
    
    return {
      folderName: timestamp ? `${generatedName}-${timestamp}` : generatedName,
      branchName: timestamp 
        ? `${config.prefix || ""}${generatedName}-${timestamp}` 
        : `${config.prefix || ""}${generatedName}`,
    };
  } catch (error) {
    console.warn("Error generating names with LLM, falling back to default:", error);
    
    // Fallback to current naming scheme
    const timestamp = Date.now();
    const sanitized = sanitizeForFilesystem(taskDescription);
    return {
      folderName: `cmux-${sanitized}-${timestamp}`,
      branchName: `${config.prefix || ""}cmux-${sanitized}-${timestamp}`,
    };
  }
}

/**
 * Call OpenAI API
 */
async function callOpenAI(provider: LLMProvider, prompt: string): Promise<string> {
  const response = await fetch(provider.endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${provider.apiKey}`,
    },
    body: JSON.stringify({
      model: provider.model,
      messages: [{ role: "user", content: prompt }],
      max_tokens: 50,
      temperature: 0.3,
    }),
  });

  if (!response.ok) {
    throw new Error(`OpenAI API error: ${response.statusText}`);
  }

  const data = await response.json();
  return data.choices[0]?.message?.content || "";
}

/**
 * Call Anthropic API
 */
async function callAnthropic(provider: LLMProvider, prompt: string): Promise<string> {
  const response = await fetch(provider.endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": provider.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: provider.model,
      max_tokens: 50,
      messages: [{ role: "user", content: prompt }],
      temperature: 0.3,
    }),
  });

  if (!response.ok) {
    throw new Error(`Anthropic API error: ${response.statusText}`);
  }

  const data = await response.json();
  return data.content[0]?.text || "";
}

/**
 * Call Gemini API
 */
async function callGemini(provider: LLMProvider, prompt: string): Promise<string> {
  const response = await fetch(`${provider.endpoint}?key=${provider.apiKey}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      contents: [
        {
          parts: [{ text: prompt }],
        },
      ],
      generationConfig: {
        maxOutputTokens: 50,
        temperature: 0.3,
      },
    }),
  });

  if (!response.ok) {
    throw new Error(`Gemini API error: ${response.statusText}`);
  }

  const data = await response.json();
  return data.candidates[0]?.content?.parts[0]?.text || "";
}

/**
 * Sanitize text for filesystem and git branch compatibility
 */
function sanitizeForFilesystem(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "") // Remove special chars except spaces and hyphens
    .trim()
    .split(/\s+/) // Split by whitespace
    .slice(0, 5) // Take first 5 words max
    .join("-")
    .substring(0, 30) // Limit length
    .replace(/--+/g, "-") // Remove multiple consecutive hyphens
    .replace(/^-+|-+$/g, ""); // Remove leading/trailing hyphens
}

/**
 * Ensure branch name is unique by checking existing branches
 */
export async function ensureUniqueBranchName(
  baseName: string,
  worktreePath: string,
  prefix: string = ""
): Promise<string> {
  const { execSync } = await import("node:child_process");
  
  try {
    // Get all existing branches
    const branches = execSync("git branch -a", { cwd: worktreePath, encoding: "utf-8" })
      .split("\n")
      .map(branch => branch.trim().replace(/^\*\s*/, "").replace(/^remotes\/[^/]+\//, ""))
      .filter(branch => branch.length > 0 && !branch.includes("HEAD"));

    let uniqueName = `${prefix}${baseName}`;
    let counter = 1;

    // Keep adding numbers until we find a unique name
    while (branches.includes(uniqueName)) {
      uniqueName = `${prefix}${baseName}-${counter}`;
      counter++;
    }

    return uniqueName;
  } catch (error) {
    // If we can't check existing branches, just return the name with timestamp
    const timestamp = Date.now();
    return `${prefix}${baseName}-${timestamp}`;
  }
}