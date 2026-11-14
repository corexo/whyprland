-- whyprland (Hyprland on WSL): adjustments for Windows.
-- Managed by womarchy-provision-user and overwritten on re-provisioning; put your
-- own changes in ~/.config/hypr/hyprland.lua instead. Loaded at its end.

-- Windows always consumes Super+L (lock) and Ctrl+Alt+Del (secure attention
-- sequence): no application, RDP client or keyboard hook ever receives them, so
-- drop bindings on them (they could never fire).
pcall(hl.unbind, "SUPER + L")
pcall(hl.unbind, "CTRL + ALT + DELETE")

-- Keyboard. The first-run setup records the Windows keyboard layouts in
-- /etc/vconsole.conf (XKBLAYOUT/XKBVARIANT, plus XKBOPTIONS such as
-- grp:alt_shift_toggle with several layouts).
local function vconsole_value(key)
  local file = io.open("/etc/vconsole.conf", "r")
  if not file then
    return nil
  end
  local value
  for line in file:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k == key then
      value = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
    end
  end
  file:close()
  return value
end

local function current(key)
  local ok, v = pcall(hl.get_config, key)
  if ok and type(v) == "string" then
    return v
  end
  return ""
end

local input = {}
-- Layout and variant only while hyprland.lua keeps Hyprland's default ("us"), or
-- when the current value cannot be read ("").
local layout = vconsole_value("XKBLAYOUT")
local cur = current("input.kb_layout")
if layout and layout ~= "" and (cur == "" or cur == "us") then
  input.kb_layout = layout
  input.kb_variant = vconsole_value("XKBVARIANT") or ""
end
-- Options are appended to whatever kb_options is in effect.
local extra = vconsole_value("XKBOPTIONS")
if extra and extra ~= "" then
  local options, seen = {}, {}
  for opt in (current("input.kb_options") .. "," .. extra):gmatch("[^,]+") do
    if not seen[opt] then
      seen[opt] = true
      options[#options + 1] = opt
    end
  end
  input.kb_options = table.concat(options, ",")
end
if next(input) then
  hl.config({ input = input })
end
