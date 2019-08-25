# Geteltorito (in Zig)

## Build
```sh
# requires master branch zig or zig 0.5 once it's released.
zig build-exe main.zig --name geteltorito
```

## Usage
```sh
# I run a X1 carbon gen 5 so I use ISOs from here:
# https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/thinkpad-x-series-laptops/thinkpad-x1-carbon-type-20hr-20hq/downloads/
./geteltorito -o image n1mur23w.iso
dd if=./image of=/dev/<some-usb-drive>
```

## License
GPLv2 (to respect the [original](http://userpages.uni-koblenz.de/~krienke/ftp/noarch/geteltorito))
