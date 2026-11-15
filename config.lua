local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Config = {}

local config_path = DataStorage:getSettingsDir() .. "/splitread.lua"

-- Default system prompt for the local (OpenAI-compatible) provider.
-- "{source}" and "{target}" are replaced with the language names, so the target
-- language is stated in the system prompt as well as in each request.
local DEFAULT_SYSTEM_PROMPT = "You are a helpful translation agent for a language learner "
    .. "who is reading a book. Translate faithfully and naturally into {target}, keeping "
    .. "the author's tone and paragraph breaks. Reply with the translation only: no notes, "
    .. "explanations or commentary."

-- The default of earlier versions. Settings files that merely stored that
-- default (every save writes all keys) are moved to the current default;
-- a prompt the user edited is left alone.
local PREVIOUS_DEFAULT_SYSTEM_PROMPTS = {
    "You are a helpful translation agent for a language learner "
        .. "who is reading a book. Translate faithfully and naturally, keep the author's tone "
        .. "and paragraph breaks, and reply with the translation only: no notes, explanations "
        .. "or commentary.",
}

local defaults = {
    provider = "google",
    source_lang = "auto",
    target_lang = "en",
    panel_height_ratio = 0.50,
    auto_translate = true,
    font_size = 14,

    -- Translations are kept on disk, one folder per book and one file per target
    -- language, and found again without a request. cache_max_mb limits all of it
    -- together (0 = no limit); when it is reached the least recently used
    -- entries are removed.
    cache_max_mb = 20,

    -- Translate this many pages after the current one in the background, so that
    -- turning the page finds the translation ready (0 = off). Needs
    -- auto_translate. Every page costs one request to the provider.
    prefetch_pages = 0,

    -- "auto": use the page text, fall back to the page image when the page has
    --         no text (scanned PDF, comics, image-only EPUB)
    -- "text": always use the page text
    -- "image": always send the page image (OCR + translate, local provider only)
    page_input = "auto",

    -- Local LLM provider (any OpenAI-compatible server: vLLM, llama.cpp, ...)
    local_url = "http://127.0.0.1:8080/v1",  -- use the server's LAN IP on an e-reader
    local_model = "",                       -- blank = ask the server (/models)
    local_system_prompt = DEFAULT_SYSTEM_PROMPT,
    local_timeout = 180,                    -- seconds to wait for a reply
    image_max_side = 1600,                  -- px, long side of the page image
}

Config.defaults = defaults
Config.DEFAULT_SYSTEM_PROMPT = DEFAULT_SYSTEM_PROMPT

function Config:load()
    local ok, settings = pcall(function()
        return LuaSettings:open(config_path)
    end)
    if not ok or not settings then
        logger.info("splitread config: using defaults")
        local result = {}
        for k, v in pairs(defaults) do result[k] = v end
        return result
    end
    local result = {}
    for k, v in pairs(defaults) do
        -- Compare against nil, not "or": a saved `false` must stay `false`.
        local saved = settings:readSetting(k)
        if saved == nil then saved = v end
        result[k] = saved
    end
    for _, old in ipairs(PREVIOUS_DEFAULT_SYSTEM_PROMPTS) do
        if result.local_system_prompt == old then
            result.local_system_prompt = DEFAULT_SYSTEM_PROMPT
        end
    end
    -- "zh" used to be the only Chinese entry; it meant Simplified Chinese.
    for _, k in ipairs({ "source_lang", "target_lang" }) do
        if result[k] == "zh" then result[k] = "zh-CN" end
    end
    return result
end

function Config:save(data)
    local ok, settings = pcall(function()
        return LuaSettings:open(config_path)
    end)
    if not ok or not settings then
        logger.info("splitread config: failed to open settings file")
        return false
    end
    for k, v in pairs(data) do
        settings:saveSetting(k, v)
    end
    settings:flush()
    logger.info("splitread config: saved")
    return true
end

return Config
