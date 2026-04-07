#!/bin/sh
stty -echo
printf 'READY\n'
exec env PS1= /bin/sh
