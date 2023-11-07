# Geteltorito (in Zig)

## Build
```sh
# requires zig 0.11 or later
zig build
```

## Usage
```sh
# I run a X1 carbon gen 5 so I use ISOs from here:
# https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/thinkpad-x-series-laptops/thinkpad-x1-carbon-type-20hr-20hq/downloads/
sudo zig-out/bin/geteltorito -o /dev/<some-usb-drive> n1mur23w.iso  # using sudo here to allow directly write to the device
```

## License
GPLv2 (to respect the [original](http://userpages.uni-koblenz.de/~krienke/ftp/noarch/geteltorito))
