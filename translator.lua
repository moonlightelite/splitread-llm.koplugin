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
        if key and key ~= "" and not key:find("your%-") then
            result[provider] = key
        end
    end
    return result
end

function Translator:isNetworkAvailable()
    return NetworkMgr:isConnected()
end

function Translator:translate(text, source_lang, target_lang, provider)
    if not text or #text == 0 then
        return nil, "No text to translate"
    end

    provider = provider or "google"
    local keys = self:loadApiKeys()

    if provider == "google" then
        return self:translateGoogle(text, source_lang, target_lang)
    elseif provider == "gemini" then
        return self:translateGemini(text, source_lang, target_lang, keys.gemini)
    else
        return nil, "Unknown provider: " .. provider
    end
end

function Translator:translateGoogle(text, source_lang, target_lang)
    local ok, result = pcall(function()
        local KOTranslator = require("ui/translator")
        local data = KOTranslator:loadPage(text, target_lang:lower(), source_lang:lower())
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

function Translator:translateGemini(text, source_lang, target_lang, api_key)
    if not api_key or api_key == "" then
        return nil, "Gemini API key not found. Add it to keys.lua in the plugin folder."
    end

    local prompt = string.format(
        "Translate the following text from %s to %s. Return only the translation, nothing else:\n\n%s",
        source_lang == "auto" and "the source language" or source_lang,
        target_lang,
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

return Translator
