local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local http = require("socket.http")
local ltn12 = require("ltn12")

local Translator = {}

function Translator:loadApiKeys()
    local ok, keys = pcall(function()
        return require("keys")
    end)
    if not ok or not keys then return {} end

    local result = {}
    for provider, key in pairs(keys) do
        if type(key) == "string" and key ~= "" and not key:find("your%-") then
            result[provider] = key
        end
    end
    return result
end

function Translator:isNetworkAvailable(provider, local_url)
    -- A local LLM on this very machine (desktop KOReader) needs no network.
    if provider == "local" and local_url then
        local host = local_url:match("^https?://([^/:]+)") or local_url:match("^([^/:]+)")
        if host and (host == "localhost" or host:find("^127%.")) then
            return true
        end
    end
    return NetworkMgr:isConnected()
end

-- opts (only used by the "local" provider):
--   opts.config       the plugin config table (local_url, local_model, ...)
--   opts.image        { data = <base64>, mime = "image/jpeg" } to send a page image
--                     instead of text (OCR + translate); `text` may then be nil
--   opts.target_name  human-readable target language name for the prompt
--   opts.source_name  human-readable source language name for the prompt
function Translator:translate(text, source_lang, target_lang, provider, opts)
    opts = opts or {}
    provider = provider or "google"

    if provider == "local" then
        if (not text or #text == 0) and not opts.image then
            return nil, "No text to translate"
        end
        return self:translateLocal(text, source_lang, target_lang, opts)
    end

    if not text or #text == 0 then
        return nil, "No text to translate"
    end

    local keys = self:loadApiKeys()

    if provider == "google" then
        return self:translateGoogle(text, source_lang, target_lang)
    elseif provider == "gemini" then
        return self:translateGemini(text, source_lang, target_lang, keys.gemini, opts)
    else
        return nil, "Unknown provider: " .. provider
    end
end

-- Google wants lower case codes, except the two Chinese ones (zh-CN is
-- Simplified, zh-TW is Traditional), which keep the case KOReader's own
-- translator sends.
local function googleLangCode(code)
    code = code:lower()
    if code == "zh-cn" then return "zh-CN" end
    if code == "zh-tw" then return "zh-TW" end
    return code
end

function Translator:translateGoogle(text, source_lang, target_lang)
    local ok, result = pcall(function()
        local KOTranslator = require("ui/translator")
        local data = KOTranslator:loadPage(text, googleLangCode(target_lang), googleLangCode(source_lang))
        if not data then return nil end
        local translated = {}
        if data[1] then
            for _, segment in ipairs(data[1]) do
                if segment[1] then
                    table.insert(translated, segment[1])
                end
            end
        end
        return table.concat(translated, "")
    end)

    if not ok or not result then
        logger.info("splitread translator: google failed:", tostring(result))
        return nil, "Translation failed: " .. tostring(result)
    end

    logger.info("splitread translator: google success, length:", #result)
    return result, nil
end

function Translator:translateGemini(text, source_lang, target_lang, api_key, opts)
    if not api_key or api_key == "" then
        return nil, "Gemini API key not found. Add it to keys.lua in the plugin folder."
    end

    -- Language names ("Chinese (Traditional)") leave no doubt about the script,
    -- which a bare code like "zh-TW" might.
    opts = opts or {}
    local prompt = string.format(
        "Translate the following text from %s to %s. Return only the translation, nothing else:\n\n%s",
        source_lang == "auto" and "the source language" or (opts.source_name or source_lang),
        opts.target_name or target_lang,
        text
    )

local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent?key=" .. api_key    local body = '{"contents":[{"parts":[{"text":"' .. prompt:gsub('"', '\\"'):gsub('\n', '\\n') .. '"}]}]}'
    local response_body = {}

    local ok, code = pcall(function()
        return http.request{
            url = url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(response_body),
        }
    end)

    if not ok then
        return nil, "Network error: " .. tostring(code)
    end

    local raw = table.concat(response_body)
    logger.info("splitread translator: gemini raw response:", raw:sub(1, 500))
    local ok2, parsed = pcall(function()
        return require("json").decode(raw)
    end)

    if not ok2 or not parsed then
        return nil, "Failed to parse Gemini response"
    end
    
    if parsed.error then
    return nil, "Gemini error: " .. (parsed.error.message or "unknown"):sub(1, 100)
    end

    local translated = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text

    if not translated then
        return nil, "No translation in Gemini response"
    end

    logger.info("splitread translator: gemini success, length:", #translated)
    return translated, nil
end

------------------------------------------------------------------------------
-- Local LLM: any OpenAI-compatible /chat/completions server
-- (vLLM, llama.cpp `llama-server`, Ollama, LM Studio, ...)
------------------------------------------------------------------------------

local LOCAL_TEMPERATURE = 0.2
local MODELS_TIMEOUT = 10
local DEFAULT_LOCAL_TIMEOUT = 180

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decodeJSON(raw)
    local ok, parsed = pcall(function() return require("json").decode(raw) end)
    if ok and type(parsed) == "table" then return parsed end
    return nil
end

local function encodeJSON(tbl)
    local ok, res, err = pcall(function() return require("json").encode(tbl) end)
    if ok and type(res) == "string" then return res end
    return nil, tostring(ok and err or res)
end

-- A JSON body has to be valid UTF-8: servers built on FastAPI/Starlette (vLLM)
-- answer HTTP 400 {"detail":"There was an error parsing the body"} otherwise.
-- Book text can carry stray bytes (a character cut in half, a bad encoding), so
-- drop every byte that is not part of a well-formed sequence.
local function toValidUTF8(s)
    if type(s) ~= "string" or not s:find("[\128-\255]") then return s end
    local out, n = {}, 0
    local len, i, run_start = #s, 1, 1
    while i <= len do
        local c = s:byte(i)
        local size = 1
        if c >= 0x80 then
            local lo, hi = 0x80, 0xBF   -- allowed range of the 2nd byte
            if c >= 0xC2 and c <= 0xDF then size = 2
            elseif c == 0xE0 then size, lo = 3, 0xA0
            elseif c == 0xED then size, hi = 3, 0x9F
            elseif c >= 0xE1 and c <= 0xEF then size = 3
            elseif c == 0xF0 then size, lo = 4, 0x90
            elseif c == 0xF4 then size, hi = 4, 0x8F
            elseif c >= 0xF1 and c <= 0xF3 then size = 4
            else size = 0 end
            local good = size > 0 and i + size - 1 <= len
            if good then
                local b2 = s:byte(i + 1)
                good = b2 >= lo and b2 <= hi
                for k = 2, size - 1 do
                    local b = s:byte(i + k)
                    if b < 0x80 or b > 0xBF then good = false end
                end
            end
            if not good then
                if i > run_start then n = n + 1; out[n] = s:sub(run_start, i - 1) end
                run_start = i + 1
                size = 1
            end
        end
        i = i + size
    end
    if run_start <= len then n = n + 1; out[n] = s:sub(run_start) end
    return table.concat(out)
end

-- Reasoning models (Qwen3, DeepSeek-R1, ...) may put their chain of thought in
-- the reply, wrapped in <think>...</think>. Drop it, keep only the answer.
local function stripThinking(s)
    s = s:gsub("<think>.-</think>", "")
    -- Chat templates that open <think> themselves only emit the closing tag.
    local _, close_end = s:find(".*</think>")
    if close_end then s = s:sub(close_end + 1) end
    return trim(s)
end

local function fillPrompt(prompt, source_name, target_name)
    prompt = prompt:gsub("{source}", function() return source_name end)
    prompt = prompt:gsub("{target}", function() return target_name end)
    return prompt
end

-- vLLM answers errors as {"object":"error","message":...}, llama.cpp and
-- OpenAI as {"error":{"message":...}}; some proxies send plain text or HTML.
local function describeServerError(parsed, raw, code)
    local msg
    if parsed then
        local e = parsed.error
        if type(e) == "table" then
            msg = e.message or e.type
        elseif type(e) == "string" then
            msg = e
        else
            msg = parsed.message
        end
    end
    if type(msg) ~= "string" or msg == "" then
        msg = trim(raw:sub(1, 120))
    end
    local hint = ""
    if code == 404 then hint = " (check the endpoint URL / model name)"
    elseif code == 401 or code == 403 then hint = " (check local_llm in keys.lua)" end
    return string.format("Local LLM error, HTTP %s: %s%s", tostring(code), msg:sub(1, 200), hint)
end

-- Users paste any of: http://host:8080, http://host:8080/v1 or the full
-- http://host:8080/v1/chat/completions. Returns the API root (used for
-- /models) and the chat completions URL, or nil if no URL is configured.
function Translator:getEndpoints(url)
    url = trim(url or "")
    if url == "" then return nil end
    if not url:find("^https?://") then url = "http://" .. url end
    url = url:gsub("/+$", "")
    if url:find("/chat/completions$") then
        return (url:gsub("/chat/completions$", "")), url
    end
    local root = url
    if not root:find("/v%d+$") then root = root .. "/v1" end
    return root, root .. "/chat/completions"
end

function Translator:getLocalHeaders()
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }
    -- Optional: only servers started with --api-key need this.
    local key = self:loadApiKeys().local_llm
    if key then
        headers["Authorization"] = "Bearer " .. key
    end
    return headers
end

-- Returns body, http_code on success (any HTTP status), or nil, error_message
-- when the request itself failed (connection refused, timeout, ...).
function Translator:httpRequest(url, method, headers, body, timeout)
    local socketutil = require("socketutil")
    local requester = url:lower():find("^https://") and require("ssl.https") or http

    local chunks = {}
    local request = {
        url = url,
        method = method,
        headers = headers or {},
        -- Plain sink on purpose: socketutil.table_sink starts its total-time
        -- clock when it is created, which would count generation time.
        sink = ltn12.sink.table(chunks),
    }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    end

    -- A non-streaming completion sends nothing until generation has finished,
    -- so the block timeout has to cover the whole generation time.
    local block_timeout, total_timeout = socketutil:set_timeout(timeout, timeout)
    local ok, ret, code = pcall(requester.request, request)
    socketutil:reset_timeout()

    if not ok then
        return nil, "Network error: " .. tostring(ret)
    end
    if ret == nil then
        local described = socketutil.describe_error
            and socketutil.describe_error(code, block_timeout, total_timeout)
        return nil, described or ("Network error: " .. tostring(code))
    end
    return table.concat(chunks), code
end

-- Model ids the server offers (GET <root>/models). Returns a list or nil, err.
function Translator:listModels(cfg)
    local root = self:getEndpoints(cfg and cfg.local_url)
    if not root then return nil, "No endpoint URL set." end

    local raw, code = self:httpRequest(root .. "/models", "GET", self:getLocalHeaders(), nil, MODELS_TIMEOUT)
    if not raw then return nil, code end
    local parsed = decodeJSON(raw)
    if code ~= 200 then return nil, describeServerError(parsed, raw, code) end

    local ids = {}
    local list = parsed and (parsed.data or parsed.models)
    if type(list) == "table" then
        for _, m in ipairs(list) do
            local id = type(m) == "table" and (m.id or m.model or m.name) or nil
            if type(id) == "string" then table.insert(ids, id) end
        end
    end
    if #ids == 0 then return nil, "The server answered but listed no models." end
    return ids
end

-- vLLM wants the exact served model name, llama.cpp ignores it. When none is
-- configured, use the first model the server reports. Failure is not fatal:
-- the request is then sent without a model and the server decides.
Translator._detected_models = {}
function Translator:detectModel(cfg)
    local root = self:getEndpoints(cfg.local_url)
    if self._detected_models[root] then return self._detected_models[root], root end
    local ids = self:listModels(cfg)
    if ids then
        self._detected_models[root] = ids[1]
        logger.info("splitread translator: detected local model:", ids[1])
        return ids[1], root
    end
    return nil, root
end

function Translator:translateLocal(text, source_lang, target_lang, opts)
    local cfg = opts.config or {}
    local root, chat_url = self:getEndpoints(cfg.local_url)
    if not chat_url then
        return nil, "Local LLM endpoint is not set. Open Settings > Local LLM settings."
    end

    local source_name = (not source_lang or source_lang == "auto")
        and "the original language" or (opts.source_name or source_lang)
    local target_name = opts.target_name or target_lang

    local clean_text = toValidUTF8(text)
    if clean_text ~= text then
        logger.warn("splitread translator: dropped invalid UTF-8 bytes from the page text")
    end
    text = clean_text
    if (not text or text == "") and not opts.image then
        return nil, "No text to translate"
    end

    local model = trim(cfg.local_model or "")
    local auto_detected = false
    if model == "" then
        model = self:detectModel(cfg)
        auto_detected = model ~= nil
    end

    local user_content
    if opts.image then
        user_content = {
            {
                type = "text",
                text = string.format(
                    "The image is a page from a book. Read all of the text on the page (OCR) "
                    .. "in natural reading order, then translate it from %s to %s. "
                    .. "Return only the translation, nothing else. "
                    .. "If the page has no readable text, reply with exactly: [no text]",
                    source_name, target_name),
            },
            {
                type = "image_url",
                image_url = { url = "data:" .. (opts.image.mime or "image/jpeg") .. ";base64," .. opts.image.data },
            },
        }
    else
        user_content = string.format(
            "Translate the following text from %s to %s. Return only the translation, nothing else:\n\n%s",
            source_name, target_name, text)
    end

    local messages = {}
    local system_prompt = trim(toValidUTF8(cfg.local_system_prompt or ""))
    if system_prompt ~= "" then
        table.insert(messages, { role = "system", content = fillPrompt(system_prompt, source_name, target_name) })
    end
    table.insert(messages, { role = "user", content = user_content })

    local body, enc_err = encodeJSON({
        model = model,  -- nil (omitted) when unknown
        messages = messages,
        temperature = LOCAL_TEMPERATURE,
        stream = false,
    })
    if not body then
        return nil, "Could not encode request: " .. tostring(enc_err)
    end

    local timeout = tonumber(cfg.local_timeout) or DEFAULT_LOCAL_TIMEOUT
    timeout = math.max(10, math.min(timeout, 1800))

    -- Never log the body: with a page image it is hundreds of KB of base64.
    logger.info("splitread translator: local request", chat_url, "model:", model or "(none)",
        opts.image and "image" or "text", #body, "bytes")

    local raw, code = self:httpRequest(chat_url, "POST", self:getLocalHeaders(), body, timeout)
    if not raw then
        return nil, code
    end

    local parsed = decodeJSON(raw)
    if code ~= 200 then
        if auto_detected then self._detected_models[root] = nil end
        return nil, describeServerError(parsed, raw, code)
    end
    if not parsed then
        return nil, "Local LLM sent a reply that is not valid JSON. Check the endpoint URL."
    end

    local choice = type(parsed.choices) == "table" and parsed.choices[1]
    local content = type(choice) == "table" and type(choice.message) == "table" and choice.message.content
    if type(content) ~= "string" then
        return nil, "No translation in the local LLM response."
    end

    local translated = stripThinking(content)
    if translated == "" then
        return nil, "The local LLM returned an empty translation (a reasoning model may have run out of tokens)."
    end

    logger.info("splitread translator: local success, length:", #translated)
    return translated, nil
end

return Translator
