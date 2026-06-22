// Netlify Function — Claude API Proxy
// timeout configurado en netlify.toml
exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, x-api-key',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
  };

  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers, body: '' };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers, body: 'Method Not Allowed' };

  try {
    const body = JSON.parse(event.body);
    const apiKey = event.headers['x-api-key'] || body.apiKey;
    if (!apiKey) return { statusCode: 401, headers, body: JSON.stringify({ error: 'API key requerida' }) };

    const payload = {
      model: body.model || 'claude-sonnet-4-6',
      max_tokens: body.max_tokens || 2000,
      messages: body.messages,
    };
    if (body.system) payload.system = body.system;

    // Use AbortController for timeout management
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 25000); // 25s timeout

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });

    clearTimeout(timeout);
    const data = await response.json();
    return { statusCode: response.status, headers, body: JSON.stringify(data) };
  } catch (err) {
    if (err.name === 'AbortError') {
      return { statusCode: 504, headers, body: JSON.stringify({ error: 'Timeout — el PDF es muy grande, intenta de nuevo' }) };
    }
    return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
  }
};
