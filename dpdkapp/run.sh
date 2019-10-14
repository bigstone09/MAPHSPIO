./build/l2fwd -l 2 -n 2 -w 0000:06:00.0 --socket-mem=1024,0 --file-prefix=mem1 -- -p 0x1 -q 1 -f $1 -c $2 --no-mac-updating


