const { getSettings } = require("./config");

function request(path, options = {}) {
  const settings = getSettings();
  if (!settings.baseUrl) {
    return Promise.reject(new Error("Please configure the AI 政务助手 API base URL first."));
  }
  if (!settings.apiKey) {
    return Promise.reject(new Error("Please configure the AI 政务助手 API key first."));
  }

  return new Promise((resolve, reject) => {
    wx.request({
      url: `${settings.baseUrl}${path}`,
      method: options.method || "GET",
      data: options.data,
      header: {
        "Content-Type": "application/json",
        "X-API-Key": settings.apiKey,
        "X-Request-ID": `mp-${Date.now()}-${Math.random().toString(16).slice(2)}`
      },
      success(response) {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          resolve(response.data);
          return;
        }
        const message = response.data?.error?.message || response.data?.message || `HTTP ${response.statusCode}`;
        reject(new Error(message));
      },
      fail(error) {
        reject(new Error(error.errMsg || "Network request failed."));
      }
    });
  });
}

function listKnowledgeBases() { return request("/api/v1/knowledge-bases"); }

function listAgents() { return request("/api/v1/agents"); }

function createKnowledgeFromURL(knowledgeBaseId, url, enableMultimodel = false) {
  return request(`/api/v1/knowledge-bases/${knowledgeBaseId}/knowledge/url`, {
    method: "POST", data: { url, enable_multimodel: enableMultimodel }
  });
}

function createSession(knowledgeBaseId, agentId) {
  const data = {};
  if (knowledgeBaseId) data.knowledge_base_id = knowledgeBaseId;
  if (agentId) data.agent_id = agentId;
  return request("/api/v1/sessions", { method: "POST", data });
}

function knowledgeChat(sessionId, query, knowledgeBaseId) {
  const data = { query };
  if (knowledgeBaseId) data.knowledge_base_ids = [knowledgeBaseId];
  return request(`/api/v1/knowledge-chat/${sessionId}`, { method: "POST", data });
}

function knowledgeChatStream(sessionId, query, knowledgeBaseId, { onChunk, onComplete, onError, onThinking }, opts) {
  var opts = opts || {};
  const settings = getSettings();
  if (!settings.baseUrl) { onError(new Error("Please configure the AI 政务助手 API base URL first.")); return null; }
  if (!settings.apiKey) { onError(new Error("Please configure the AI 政务助手 API key first.")); return null; }

  const data = { query: query };
  if (knowledgeBaseId) data.knowledge_base_ids = [knowledgeBaseId];
  data.channel = "web";
  if (opts.agentEnabled && opts.agentId) {
    data.agent_enabled = true;
    data.agent_id = opts.agentId;
  }
  if (opts.webSearchEnabled) data.web_search_enabled = true;

  let buffer = "";
  let fullResponse = "";
  let requestTask = null;
  let completed = false;

  function decodeUtf8(bytes) {
    var out = "", i = 0, c = 0, c2 = 0, c3 = 0;
    while (i < bytes.length) {
      c = bytes[i];
      if (c < 128) { out += String.fromCharCode(c); i++; }
      else if (c < 224) { c2 = bytes[i + 1]; out += String.fromCharCode(((c & 31) << 6) | (c2 & 63)); i += 2; }
      else if (c < 240) { c2 = bytes[i + 1]; c3 = bytes[i + 2]; out += String.fromCharCode(((c & 15) << 12) | ((c2 & 63) << 6) | (c3 & 63)); i += 3; }
      else { i += 4; }
    }
    return out;
  }

  const processChunk = (chunkText) => {
    fullResponse += chunkText;
    buffer += chunkText;
    while (buffer.includes("\n\n")) {
      const idx = buffer.indexOf("\n\n");
      const block = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx).replace(/^\n+/, "");
      if (!block) continue;
      let dataStr = "";
      block.split("\n").forEach((line) => {
        if (line.startsWith("data:")) dataStr += line.slice(5).trim();
      });
      if (!dataStr) continue;
      try {
        const payload = JSON.parse(dataStr);
        if (payload.response_type === "answer" && payload.content) onChunk(payload.content);
      } catch (_) {}
    }
  };

  var chatPath = (opts.agentEnabled && opts.agentId) ? "/api/v1/agent-chat/" : "/api/v1/knowledge-chat/";
  requestTask = wx.request({
    url: `${settings.baseUrl}${chatPath}${sessionId}`,
    method: "POST", data, enableChunked: true, timeout: 300000,
    header: {
      "Content-Type": "application/json",
      "X-API-Key": settings.apiKey,
      "X-Request-ID": `mp-${Date.now()}-${Math.random().toString(16).slice(2)}`
    },
    success() { if (!completed) { completed = true; onComplete(fullResponse); } },
    fail(error) { if (!completed) { completed = true; onError(new Error(error.errMsg || "Network request failed.")); } }
  });

  requestTask.onChunkReceived((res) => { if (res.data instanceof ArrayBuffer) processChunk(decodeUtf8(new Uint8Array(res.data))); });
  return { abort() { if (requestTask && !completed) { completed = true; requestTask.abort(); } } };
}

function getSuggestedQuestions(agentId, kbId, limit) {
  limit = limit || 6;
  var path = "/api/v1/agents/" + agentId + "/suggested-questions?limit=" + limit;
  if (kbId) path += "&knowledge_base_ids=" + encodeURIComponent(kbId);
  return request(path);
}

module.exports = {
  createKnowledgeFromURL, createSession, knowledgeChat, knowledgeChatStream,
  getSuggestedQuestions, listAgents, listKnowledgeBases, request
};
