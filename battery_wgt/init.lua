local awful = require("awful")
local gears = require("gears")
local naughty = require("naughty")
local wibox = require("wibox")

local timer = gears.timer
local watch = awful.spawn and awful.spawn.with_line_callback

-------------------------------------------------------------------------------
-- Utils
-------------------------------------------------------------------------------

local to_lower = string.lower

local function file_exists(command)
    local f = io.open(command)
    if f then f:close() end
    return f and true or false
end

local function readfile(command)
    local file = io.open(command)
    if not file then return nil end
    local text = file:read('*all')
    file:close()
    return text
end

local function color_tags(color)
    if color
        then return '<span color="' .. color .. '">', '</span>'
        else return '', ''
    end
end

local function round(value)
    return math.floor(value + 0.5)
end

local function trim(s)
    if not s then return nil end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function read_trim(filename)
    return trim(readfile(filename)) or ""
end

local function substitute(template, context)
    if type(template) == "string" then
        return (template:gsub("%${([%w_]+)}", function(key)
            return tostring(context[key] or "Err!")
        end))
    else
        -- function / functor:
        return template(context)
    end
end

local function lookup_by_limits(limits, value)
    if type(limits) == "table" then
        local last = nil
        if value then
            for k, v in ipairs(limits) do
                if (value <= v[1]) then
                    return v[2]
                end
                last = v[2]
            end
        end
        return last
    else
        return limits
    end
end

-------------------------------------------------------------------------------
-- Battery widget
-------------------------------------------------------------------------------

local battery_wgt = {}
local sysfs_names = {
    charging = {
        present   = "present",
        state     = "status",
        rate      = "current_now",
        charge    = "charge_now",
        capacity  = "charge_full",
        design    = "charge_full_design",
        percent   = "capacity",
    },
    discharging = {
        present   = "present",
        state     = "status",
        rate      = "power_now",
        charge    = "energy_now",
        capacity  = "energy_full",
        design    = "energy_full_design",
        percent   = "capacity"
    },
}

local constants = {
    discharging = -1,
    static = 0,
    charging = 1,
}

function battery_wgt:new(args)
    -- initialize per adapter
    if args.adapter then
        return setmetatable({}, {__index = self}):init(args)
    end

    -- detect adapters and initialize them
    local widgets = { layout = wibox.layout.fixed.horizontal }
    local batteries, mains, usb, ups = self:discover()
    local ac = mains[1] or usb[1] or ups[1]
    for _, adapter in ipairs(batteries) do
        local _args = setmetatable({adapter = adapter, ac = ac}, {__index = args})
        table.insert(widgets, self(_args).widget)
    end
    return widgets
end

function battery_wgt:discover()
    local pow = "/sys/class/power_supply/"
    local adapters = { Battery = {}, UPS = {}, Mains = {}, USB = {} }
    for adapter in io.popen("ls -1 " .. pow):lines() do
        local type = read_trim(pow .. adapter .. "/type")
        table.insert(adapters[type], adapter)
    end
    return adapters.Battery, adapters.Mains, adapters.USB, adapters.UPS
end

function battery_wgt:init(args)
    self.ac = args.ac or "AC"
    self.adapter = args.adapter or "BAT0"
    self.ac_prefix = "AC: "
    self.battery_prefix = "Bat: "
    self.percent_colors = args.percent_colors or args.limits or {
        { 25, "red"   },
        { 50, "orange"},
        {100, "green" },
    }

    self.widget_text = "${AC_BAT}${color_on}${percent}%${color_off}"
    self.tooltip_text = "Battery ${state}${time_estimated}\nCapacity: ${capacity_percent}%"

    self.alert_threshold = 10
    self.alert_text = "${AC_BAT}${time_estimated}"
    self.low_battery_notified = false

    self.widget = wibox.widget.textbox()
    self.widget.font = args.widget_font
    self.tooltip = awful.tooltip({objects={self.widget}})

    self:update()
    self:setup_refresh_timer()
    self:subscribe_on_changes()

    return self
end

function battery_wgt:setup_refresh_timer()
    self.timer = timer({ timeout = 10 })
    self.timer:connect_signal("timeout", function() self:update() end)
    self.timer:start()
end

function battery_wgt:subscribe_on_changes()
    self.listener = watch("acpi_listen", {
        stdout = function(_) self:update() end,
    })
    awesome.connect_signal("exit", function()
        awesome.kill(self.listener, awesome.unix_signal.SIGTERM)
    end)
end

function battery_wgt:get_state()
    local pow   = "/sys/class/power_supply/"
    local ac    = pow .. self.ac
    local bat   = pow .. self.adapter
    local sysfs = (file_exists(bat.."/"..sysfs_names.charging.rate)
                   and sysfs_names.charging
                   or sysfs_names.discharging)

    -- if there is no battery on this machine
    if not sysfs.state then return nil end

    -- system values
    local r = {
        state     = to_lower (read_trim(bat.."/"..sysfs.state)),
        present   = tonumber(read_trim(bat.."/"..sysfs.present)),
        rate      = tonumber(read_trim(bat.."/"..sysfs.rate)),
        charge    = tonumber(read_trim(bat.."/"..sysfs.charge)),
        capacity  = tonumber(read_trim(bat.."/"..sysfs.capacity)),
        design    = tonumber(read_trim(bat.."/"..sysfs.design)),
        percent   = tonumber(read_trim(bat.."/"..sysfs.percent)),
    }

    r.ac_state = tonumber(read_trim(ac.."/online"))

    if r.state == "unknown" then
        r.state = "charged"
    end

    if r.percent == nil and r.charge and r.capacity then
        r.percent = round(r.charge * 100 / r.capacity)
    end

    return r
end

function battery_wgt:update()
    local ctx = self:get_state()

    -- If there is no battery on this machine.
    if not ctx then return nil end

    -- AC/battery prefix
    ctx.AC_BAT  = (ctx.ac_state == 1
            and lookup_by_limits(self.ac_prefix, ctx.percent)
            or lookup_by_limits(self.battery_prefix, ctx.percent)
            or "Err!")

    -- Colors
    ctx.color_on, ctx.color_off = color_tags(
            lookup_by_limits(self.percent_colors, ctx.percent))

    -- estimate time
    ctx.charge_direction = constants.static
    ctx.time_left = nil -- time until charging/discharging complete
    ctx.time_text = ""
    ctx.time_estimated = ""

    if ctx.rate and ctx.rate ~= 0 then
        if not ctx.state or ctx.state == "discharging" then
            ctx.charge_direction = constants.discharging
            ctx.time_left = ctx.charge / ctx.rate
        elseif ctx.state == "charging" then
            ctx.charge_direction = constants.charging
            ctx.time_left = (ctx.capacity - ctx.charge) / ctx.rate
        end
    end

    if ctx.time_left then
        ctx.hours   = math.floor((ctx.time_left))
        ctx.minutes = math.floor((ctx.time_left - ctx.hours) * 60)
        if ctx.hours > 0
        then ctx.time_text = ctx.hours .. "h " .. ctx.minutes .. "m"
        else ctx.time_text =                      ctx.minutes .. "m"
        end
        ctx.time_estimated = ": " .. ctx.time_text .. " remaining"
    end

    -- capacity text
    if ctx.capacity and ctx.design then
        ctx.capacity_percent = round(ctx.capacity/ctx.design*100)
    end

    -- update text
    self.widget:set_markup(substitute(self.widget_text, ctx))
    self.tooltip:set_text(substitute(self.tooltip_text, ctx))

    -- notifications
    if (ctx.charge_direction == constants.discharging and ctx.percent and ctx.percent <= self.alert_threshold)
    then
        if not self.low_battery_notified
        then
            self:notify_low_battery(substitute(self.alert_text, ctx))
        end
    else
        self.low_battery_notified = false
    end
end

function battery_wgt:notify_low_battery(text)
    naughty.notify({
        title = "Critically low battery!",
        icon = "/home/waster/Downloads/no_energy.jpg",
        text = text,
        preset = naughty.config.presets.critical,
        timeout = 10
    })
    self.low_battery_notified = true
end

return setmetatable(battery_wgt, {
    __call = battery_wgt.new,
})
