#
# charkyd
#
# 



# systemd-analyze dump | awk '/-> Unit /{u=$3} /Unit Load State: /{l=$4} /Unit Active State: /{s=$4} /^->/{print u" "l": "s}'


# check if something should be running or what state it should be in

# Report current state of all
