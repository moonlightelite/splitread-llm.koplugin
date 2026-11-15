-- Tidies the text of a translation before it is shown in the panel.
--
-- Models like to separate paragraphs with a blank line ("\n\n"), which wastes
-- vertical space in a panel that is only a few lines high. The page text we send
-- has single line breaks between paragraphs, so the translation gets them too:
-- blank lines are removed, unless the source text itself has blank lines (then at
-- most one is kept between two paragraphs). Everything else is left alone: single
-- line breaks, indentation, spaces inside lines.

local TextFormat = {}

-- A line that shows nothing: empty, or only spaces, tabs and invisible characters.
local function isBlank(line)
    local s = line:gsub("\194\160", "")      -- no-break space
                  :gsub("\227\128\128", "")  -- ideographic space
                  :gsub("\226\128\139", "")  -- zero width space
                  :gsub("\239\187\191", "")  -- byte order mark
    return s:find("^%s*$") ~= nil
end

local function lines(text)
    return (text:gsub("\r\n?", "\n") .. "\n"):gmatch("(.-)\n")
end

-- Does `text` have a blank line between two lines of text? (Blank lines at its
-- start or end do not count.)
function TextFormat.hasBlankLines(text)
    if type(text) ~= "string" then return false end
    local seen_text, pending_blank = false, false
    for line in lines(text) do
        if isBlank(line) then
            if seen_text then pending_blank = true end
        else
            if pending_blank then return true end
            seen_text = true
        end
    end
    return false
end

-- `translation` without the extra blank lines. `source` is the text that was
-- translated (nil when unknown, e.g. a page image): blank lines are only kept when
-- it has some itself. Safe to apply more than once.
function TextFormat.translation(translation, source)
    if type(translation) ~= "string" then return translation end
    local keep_blank = TextFormat.hasBlankLines(source)
    local out, blank_run = {}, 0
    for line in lines(translation) do
        if isBlank(line) then
            blank_run = blank_run + 1
        else
            if keep_blank and blank_run > 0 and #out > 0 then
                out[#out + 1] = ""      -- one blank line, however many there were
            end
            blank_run = 0
            out[#out + 1] = (line:gsub("[ \t]+$", ""))
        end
    end
    return table.concat(out, "\n")
end

return TextFormat
