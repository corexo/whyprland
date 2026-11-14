-- whyprland: default Hyprland configuration (Lua, Hyprland 0.56).
-- Created by womarchy-provision-user only when missing: this file is yours to edit.
-- Reference: https://wiki.hypr.land/Configuring/Start/ and Hyprland's example/hyprland.lua.
-- require("name") loads ~/.config/hypr/name.lua.

-- Monitors follow Windows (womarchy-session writes the rules; see monitors.lua).
require("monitors")

local terminal = "kitty"
local menu     = "fuzzel"
local mainMod  = "SUPER"

---- Autostart ----
hl.on("hyprland.start", function()
  -- uwsm waits for WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE in the systemd
  -- environment and ends the session after ~15 s without them.
  hl.exec_cmd("uwsm finalize")
  hl.exec_cmd("waybar")
  hl.exec_cmd("mako")
  -- hyprpolkitagent needs hyprtoolkit, which needs DRM/dmabuf (not in WSL); GTK works.
  hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
end)

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

---- Look ----
hl.config({
  general = {
    gaps_in = 4,
    gaps_out = 8,
    border_size = 2,
    col = {
      active_border = "rgba(33ccffee)",
      inactive_border = "rgba(595959aa)",
    },
    layout = "dwindle",
  },
  decoration = {
    rounding = 6,
  },
  dwindle = {
    preserve_split = true,
  },
  input = {
    -- kb_layout/kb_variant/kb_options come from /etc/vconsole.conf (womarchy.lua);
    -- setting kb_layout here to something other than "us" overrides that.
    follow_mouse = 1,
  },
})

---- Keys ----
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + Space", hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + Q", hl.dsp.window.close())
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
-- Log out: ends the session and returns to the Windows prompt.
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("uwsm stop || hyprctl dispatch 'hl.dsp.exit()'"))

hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- SUPER+1..9: switch workspace; SUPER+SHIFT+1..9: move the window there.
for i = 1, 9 do
  hl.bind(mainMod .. " + " .. i,         hl.dsp.focus({ workspace = i }))
  hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })

-- Screenshot of a region to the clipboard.
hl.bind("Print", hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | wl-copy"))

-- Your own settings go here or in files you require() from here.

-- WSL adjustments (keyboard layout from Windows, keys Windows reserves). Keep last.
require("womarchy")
