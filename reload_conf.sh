#!/bin/sh
pidfile=stasbot.pid
if [ -e "$pidfile" ]
then
	kill -HUP `cat "$pidfile"`
fi
