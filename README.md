# My custom setup of AwesomeWM

Checkout to `~/.config/awesome` by:

```shell
git clone --recurse-submodules git@github.com:akuskis/awesomewm_config.git
```

Wallpaper location: `~/.config/awesome/wallpaper.jpg`

### Dependencies:

Screen locker: `xtrlock`

Laptop screen brightness: `brightnessctl`

```bash
sudo apt install xtrlock brightnessctl

# permissions to `brightnessctl`
sudo gpasswd -a [USER_NAME] video
```

### Handle resolution

Setup DPI:

```bash
$ cat ~/.Xresources 
Xft.dpi: 188
```

DPI calculator: https://dpi.lv/
