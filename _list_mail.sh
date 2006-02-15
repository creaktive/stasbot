#!/bin/sh
exec grep -v '^\[' db/stasbot_mail.lst | sort -u
