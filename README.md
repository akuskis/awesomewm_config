# My custom setup of AwesomeWM

Checkout to `~/.config/awesome`

Wallpaper location: `~/.config/awesome/wallpaper.jpg`

### Dependencies:

Screen locker: `xtrlock`

```bash
sudo apt install xtrlock
```

Battery: `acpid`

```bash
systemctl enable acpid
```

### Handle resolution

Setup DPI:

```bash
$ cat ~/.Xresources 
Xft.dpi: 188
```

DPI calculator: https://dpi.lv/

### Notes

Original AwesomeWM widgets can be found here: https://github.com/deficient
