local UIManager = require("ui/uimanager")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local logger = require("logger")

local LANGUAGES = {
    { code = "auto", name = "Auto detect" },
    { code = "de",   name = "German" },
    { code = "en",   name = "English" },
    { code = "fr",   name = "French" },
    { code = "es",   name = "Spanish" },
    { code = "it",   name = "Italian" },
    { code = "pt",   name = "Portuguese" },
    { code = "nl",   name = "Dutch" },
    { code = "pl",   name = "Polish" },
    { code = "ru",   name = "Russian" },
    { code = "ja",   name = "Japanese" },
    { code = "zh-CN", name = "Chinese (Simplified)" },
    { code = "zh-TW", name = "Chinese (Traditional)" },
    { code = "ar",   name = "Arabic" },
    { code = "tr",   name = "Turkish" },
    { code = "ko",   name = "Korean" },
}

local FONT_SIZES = {10, 12, 14, 16, 18, 20, 22}

local PANEL_SIZES = {
    { ratio = 0.25, name = "Small (25%)" },
    { ratio = 0.35, name = "Medium (35%)" },
    { ratio = 0.45, name = "Large (45%)" },
}

local PROVIDERS = {
    { key = "google", name = "KOReader (Google Translate)", requires_key = false },
    { key = "gemini", name = "Gemini", requires_key = true },
    { key = "local", name = "Local LLM (OpenAI-compatible)", requires_key = false },
}

local PAGE_INPUTS = {
    { key = "auto", name = "Auto (text, or image if no text)" },
    { key = "text", name = "Text only" },
    { key = "image", name = "Page image (OCR, Local LLM only)" },
}


local UI = {}

function UI:getLanguageName(code)
    for _, lang in ipairs(LANGUAGES) do
        if lang.code == code then
            return lang.name
        end
    end
    return code:upper()
end

function UI:getPanelSizeName(ratio)
    for _, size in ipairs(PANEL_SIZES) do
        if size.ratio == ratio then
            return size.name
        end
    end
    return tostring(math.floor(ratio * 100)) .. "%"
end

function UI:getProviderName(key)
    for _, p in ipairs(PROVIDERS) do
        if p.key == key then return p.name end
    end
    return key
end

function UI:getPageInputName(key)
    for _, p in ipairs(PAGE_INPUTS) do
        if p.key == key then return p.name end
    end
    return key
end

-- Long values (URL, prompt) must not blow up a button label.
local function shorten(text, max_len)
    text = (text or ""):gsub("%s+", " ")
    if #text > max_len then
        -- Cut on a UTF-8 character boundary.
        local cut = max_len
        while cut > 1 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
            cut = cut - 1
        end
        text = text:sub(1, cut) .. "…"
    end
    return text
end

function UI:showPageInputPicker(current_key, on_select, on_done)
    local input_dialog
    local buttons = {}

    for _, p in ipairs(PAGE_INPUTS) do
        local is_current = p.key == current_key
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "  ") .. p.name,
                callback = function()
                    UIManager:close(input_dialog)
                    on_select(p.key)
                    on_done()
                end,
            }
        })
    end

    input_dialog = ButtonDialogTitle:new{
        title = "Page input",
        buttons = buttons,
    }
    UIManager:show(input_dialog)
end

-- Single- or multi-line text entry. `on_save(text)` gets the new value;
-- `on_done()` runs afterwards (also on cancel) to return to the caller's menu.
function UI:showTextInput(title, current, opts, on_save, on_done)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local row = {
        {
            text = "Cancel",
            id = "close",
            callback = function()
                UIManager:close(dialog)
                on_done()
            end,
        },
    }
    if opts.default then
        table.insert(row, {
            text = "Default",
            callback = function()
                dialog:setInputText(opts.default)
            end,
        })
    end
    table.insert(row, {
        text = "Save",
        is_enter_default = not opts.multiline,
        callback = function()
            local value = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
            UIManager:close(dialog)
            on_save(value)
            on_done()
        end,
    })
    dialog = InputDialog:new{
        title = title,
        input = current or "",
        input_hint = opts.hint,
        description = opts.description,
        allow_newline = opts.multiline or false,
        fullscreen = opts.multiline or false,
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Asks the server for its model list and reports the result.
function UI:testLocalConnection(config, on_done)
    local InfoMessage = require("ui/widget/infomessage")
    local Translator = require("translator")
    local info = InfoMessage:new{ text = "Contacting the server..." }
    UIManager:show(info)
    UIManager:scheduleIn(0.2, function()
        local ids, err = Translator:listModels(config)
        UIManager:close(info)
        local text
        if ids then
            text = "Connected. Models on the server:\n" .. table.concat(ids, "\n", 1, math.min(#ids, 5))
            if #ids > 5 then text = text .. "\n… and " .. (#ids - 5) .. " more" end
        else
            text = "Connection failed:\n" .. tostring(err)
        end
        UIManager:show(InfoMessage:new{
            text = text,
            dismiss_callback = on_done,
        })
    end)
end

-- Pick the model from the list the server reports (GET <root>/models). Typing a
-- name stays possible ("Type a name..."), and is also what the user gets when
-- the server cannot list its models.
function UI:showModelPicker(config, Config, on_done)
    local InfoMessage = require("ui/widget/infomessage")
    local Translator = require("translator")

    local function save(value)
        config.local_model = value
        Config:save(config)
    end
    local function type_name()
        self:showTextInput("Model name", config.local_model, {
            hint = "leave empty to use the server's model",
            description = "vLLM needs the served model name. llama.cpp ignores it.",
        }, save, on_done)
    end

    local info = InfoMessage:new{ text = "Asking the server for its models..." }
    UIManager:show(info)
    -- Let the message paint first: the request blocks until the server answers.
    UIManager:scheduleIn(0.2, function()
        local ids, err = Translator:listModels(config)
        UIManager:close(info)
        if not ids then
            UIManager:show(InfoMessage:new{
                text = "Could not get the model list:\n" .. tostring(err) .. "\n\nType the model name instead.",
                dismiss_callback = type_name,
            })
            return
        end

        local picker
        local buttons = {}
        local current = config.local_model or ""
        local function add(label, value, is_current)
            table.insert(buttons, {
                {
                    text = (is_current and "✓ " or "  ") .. label,
                    callback = function()
                        UIManager:close(picker)
                        save(value)
                        on_done()
                    end,
                },
            })
        end

        add("Auto (the server's first model)", "", current == "")
        local listed = false
        for _, id in ipairs(ids) do
            if id == current then listed = true end
        end
        if current ~= "" and not listed then
            -- Typed earlier by hand: keep it visible instead of silently dropping it.
            add(shorten(current, 44) .. " (not listed)", current, true)
        end
        for _, id in ipairs(ids) do
            add(shorten(id, 48), id, id == current)
        end
        table.insert(buttons, {
            {
                text = "Type a name…",
                callback = function()
                    UIManager:close(picker)
                    type_name()
                end,
            },
        })
        table.insert(buttons, {
            {
                text = "Cancel",
                callback = function()
                    UIManager:close(picker)
                    on_done()
                end,
            },
        })

        picker = ButtonDialogTitle:new{
            title = string.format("Model (%d on the server)", #ids),
            buttons = buttons,
            tap_close_callback = on_done,
        }
        UIManager:show(picker)
    end)
end

function UI:showLocalSettingsDialog(config, Config, on_done)
    if self.local_dialog then
        UIManager:close(self.local_dialog)
        self.local_dialog = nil
    end

    local dialog
    local function reopen()
        self:showLocalSettingsDialog(config, Config, on_done)
    end
    local function save(key)
        return function(value)
            config[key] = value
            Config:save(config)
        end
    end

    dialog = ButtonDialogTitle:new{
        title = "Local LLM settings",
        buttons = {
            {
                {
                    text = "Server: " .. shorten(config.local_url, 40),
                    callback = function()
                        UIManager:close(dialog)
                        self:showTextInput("Server URL and port", config.local_url, {
                            hint = "http://192.168.1.50:8000/v1",
                            description = "Address and port of any OpenAI-compatible server "
                                .. "(vLLM, llama.cpp, Ollama, LM Studio, ...). Examples:\n"
                                .. "http://192.168.1.50:8000/v1\n"
                                .. "192.168.1.50:8080\n"
                                .. "https://llm.example.com/v1\n"
                                .. "On an e-reader use the server's LAN address, not localhost.",
                            default = Config.defaults.local_url,
                        }, save("local_url"), reopen)
                    end,
                },
            },
            {
                {
                    text = "Model: " .. (config.local_model ~= "" and shorten(config.local_model, 40) or "ask the server"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showModelPicker(config, Config, reopen)
                    end,
                },
            },
            {
                {
                    text = "System prompt: " .. shorten(config.local_system_prompt, 28),
                    callback = function()
                        UIManager:close(dialog)
                        self:showTextInput("System prompt", config.local_system_prompt, {
                            multiline = true,
                            hint = "You are a helpful translation agent...",
                            description = "Sent as the system message. {source} and {target} are "
                                .. "replaced by the language names. Empty = no system prompt.",
                            default = Config.DEFAULT_SYSTEM_PROMPT,
                        }, save("local_system_prompt"), reopen)
                    end,
                },
            },
            {
                {
                    text = "Test connection",
                    callback = function()
                        UIManager:close(dialog)
                        self:testLocalConnection(config, reopen)
                    end,
                },
            },
            {
                {
                    text = "Back",
                    callback = function()
                        UIManager:close(dialog)
                        self.local_dialog = nil
                        on_done()
                    end,
                },
            },
        },
    }
    self.local_dialog = dialog
    UIManager:show(dialog)
end

function UI:showProviderPicker(current_key, on_select, on_done)
    local provider_dialog
    local buttons = {}

    table.insert(buttons, {
        {
            text = "⚠ Add API keys to keys.lua in the plugin folder",
            callback = function() end,
        }
    })

    for _, p in ipairs(PROVIDERS) do
        local is_current = p.key == current_key
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "  ") .. p.name,
                callback = function()
                    UIManager:close(provider_dialog)
                    on_select(p.key)
                    on_done()
                end,
            }
        })
    end

    provider_dialog = ButtonDialogTitle:new{
        title = "Translation Provider",
        buttons = buttons,
    }
    UIManager:show(provider_dialog)
end

function UI:showLanguagePicker(title, current_code, on_select, on_done)
    local picker_dialog
    local buttons = {}
    for _, lang in ipairs(LANGUAGES) do
        local is_current = lang.code == current_code
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "  ") .. lang.name,
                callback = function()
                    UIManager:close(picker_dialog)
                    on_select(lang.code)
                    on_done()
                end,
            }
        })
    end
    picker_dialog = ButtonDialogTitle:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(picker_dialog)
end

function UI:showFontSizePicker(current_size, on_select, on_done)
    local font_dialog
    local buttons = {}

    table.insert(buttons, {
        {
            text = "⚠ Larger fonts may cut off translation text",
            callback = function() end,
        }
    })

    for _, size in ipairs(FONT_SIZES) do
        local is_current = size == current_size
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "  ") .. tostring(size) .. " pt",
                callback = function()
                    UIManager:close(font_dialog)
                    on_select(size)
                    on_done()
                end,
            }
        })
    end

    font_dialog = ButtonDialogTitle:new{
        title = "Translation Font Size",
        buttons = buttons,
    }
    UIManager:show(font_dialog)
end

function UI:showPanelSizePicker(current_ratio, on_select, on_done)
    local panel_dialog
    local buttons = {}

    table.insert(buttons, {
        {
            text = "⚠ Reopen book to apply panel size change",
            callback = function() end,
        }
    })

    for _, size in ipairs(PANEL_SIZES) do
        local is_current = size.ratio == current_ratio
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "  ") .. size.name,
                callback = function()
                    UIManager:close(panel_dialog)
                    on_select(size.ratio)
                    on_done()
                end,
            }
        })
    end

    panel_dialog = ButtonDialogTitle:new{
        title = "Panel Size",
        buttons = buttons,
    }
    UIManager:show(panel_dialog)
end

function UI:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
    logger.info("splitread: showSettingsDialog called")

    if self.current_dialog then
        UIManager:close(self.current_dialog)
        self.current_dialog = nil
    end

    UIManager:scheduleIn(0.1, function()
        local dialog
        dialog = ButtonDialogTitle:new{
            title = "splitread Settings",
            buttons = {
                {
                    {
                        text = "Translate this page now",
                        callback = function()
                            UIManager:close(dialog)
                            self.current_dialog = nil
                            if on_translate then on_translate() end
                        end,
                    },
                },
                {
                    {
                        text = "Source language: " .. self:getLanguageName(config.source_lang),
                        callback = function()
                            UIManager:close(dialog)
                            self:showLanguagePicker(
                                "Source Language",
                                config.source_lang,
                                function(code)
                                    config.source_lang = code
                                    Config:save(config)
                                end,
                                function()
                                    self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                                end
                            )
                        end,
                    },
                },
                {
                    {
                        text = "Target language: " .. self:getLanguageName(config.target_lang),
                        callback = function()
                            UIManager:close(dialog)
                            self:showLanguagePicker(
                                "Target Language",
                                config.target_lang,
                                function(code)
                                    config.target_lang = code
                                    Config:save(config)
                                end,
                                function()
                                    self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                                end
                            )
                        end,
                    },
                },
                {
                    {
                        text = "Auto-translate: " .. (config.auto_translate and "ON" or "OFF"),
                        callback = function()
                            config.auto_translate = not config.auto_translate
                            Config:save(config)
                            UIManager:close(dialog)
                            self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                        end,
                    },
                },
                {
    {
        text = "Provider: " .. self:getProviderName(config.provider or "google"),
        callback = function()
            UIManager:close(dialog)
            self:showProviderPicker(
                config.provider or "google",
                function(provider_key)
                    config.provider = provider_key
                    Config:save(config)
                end,
                function()
                    self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                end
            )
        end,
    },
},
                {
                    {
                        text = "Page input: " .. self:getPageInputName(config.page_input or "auto"),
                        callback = function()
                            UIManager:close(dialog)
                            self:showPageInputPicker(
                                config.page_input or "auto",
                                function(key)
                                    config.page_input = key
                                    Config:save(config)
                                end,
                                function()
                                    self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                                end
                            )
                        end,
                    },
                },
                {
                    {
                        text = "Local LLM settings...",
                        callback = function()
                            UIManager:close(dialog)
                            self:showLocalSettingsDialog(config, Config, function()
                                self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                            end)
                        end,
                    },
                },
                {
                    {
                        text = "Font size: " .. tostring(config.font_size) .. " pt",
                        callback = function()
                            UIManager:close(dialog)
                            self:showFontSizePicker(
                                config.font_size,
                                function(size)
                                    config.font_size = size
                                    Config:save(config)
                                end,
                                function()
                                    self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                                end
                            )
                        end,
                    },
                },
                {
                    {
                        text = "Panel size: " .. self:getPanelSizeName(config.panel_height_ratio),
                        callback = function()
                            UIManager:close(dialog)
                            self:showPanelSizePicker(
                                config.panel_height_ratio,
                                function(ratio)
                                    config.panel_height_ratio = ratio
                                    Config:save(config)
                                    if on_panel_resize then
                                        on_panel_resize(ratio)
                                    end
                                end,
                                function()
                                    self:showSettingsDialog(config, Config, on_refresh, on_panel_resize, on_translate)
                                end
                            )
                        end,
                    },
                },
                {
                    {
                        text = "Close",
                        callback = function()
                            UIManager:close(dialog)
                            self.current_dialog = nil
                            
                        end,
                    },
                },
            },
        }
        self.current_dialog = dialog
        UIManager:show(dialog)
    end)
end

return UI
