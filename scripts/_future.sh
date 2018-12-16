ynh_check_var () {
    test -n "$1" || ynh_die "$2"
}

ynh_export () {
    local ynh_arg=""
    for var in $@;
    do
        ynh_arg=$(echo $var | awk '{print toupper($0)}')
        ynh_arg="YNH_APP_ARG_$ynh_arg"
        export $var=${!ynh_arg}
    done
}

# Save listed var in YunoHost app settings
# usage: ynh_save_args VARNAME1 [VARNAME2 [...]]
ynh_save_args () {
    for var in $@;
    do
        ynh_app_setting_set $app $var ${!var}
    done
}

ynh_sso_access () {
    ynh_app_setting_set $app unprotected_uris "/"

    if [[ $is_public -eq 0 ]]; then
        ynh_app_setting_set $app protected_uris "$1"
    fi
    sudo yunohost app ssowatconf
}
ynh_configure () {
    local TEMPLATE=$1
    local DEST=$2
    mkdir -p "$(dirname $DEST)"
    if [ -f '../manifest.json' ] ; then
        ynh_render_template "${YNH_CWD}/../conf/$TEMPLATE.j2" "$DEST"
    else
        ynh_render_template "${YNH_CWD}/../settings/conf/$TEMPLATE.j2" "$DEST"
    fi
}

ynh_configure_nginx () {
    ynh_configure nginx.conf /etc/nginx/conf.d/$domain.d/$app.conf
    sudo service nginx reload
}

# Upgrade
ynh_read_json () {
    python3 -c "import sys, json;print(json.load(open('$1'))['$2'])"
}

ynh_read_manifest () {
    if [ -f '../manifest.json' ] ; then
        ynh_read_json '../manifest.json' "$1"
    else
        ynh_read_json '../settings/manifest.json' "$1"
    fi
}


is_stretch () {
	if [ "$(ynh_get_debian_release)" == "stretch" ]
	then
		return 0
	else
		return 1
	fi
}

is_jessie () {
	if [ "$(ynh_get_debian_release)" == "jessie" ]
	then
		return 0
	else
		return 1
	fi
}
# Internal helper design to allow helpers to use getopts to manage their arguments
#
# example: function my_helper()
# {
#     declare -Ar args_array=( [a]=arg1= [b]=arg2= [c]=arg3 )
#     local arg1
#     local arg2
#     local arg3
#     ynh_handle_getopts_args "$@"
#
#     [...]
# }
# my_helper --arg1 "val1" -b val2 -c
#
# usage: ynh_handle_getopts_args "$@"
# | arg: $@    - Simply "$@" to tranfert all the positionnal arguments to the function
#
# This helper need an array, named "args_array" with all the arguments used by the helper
# 	that want to use ynh_handle_getopts_args
# Be carreful, this array has to be an associative array, as the following example:
# declare -Ar args_array=( [a]=arg1 [b]=arg2= [c]=arg3 )
# Let's explain this array:
# a, b and c are short options, -a, -b and -c
# arg1, arg2 and arg3 are the long options associated to the previous short ones. --arg1, --arg2 and --arg3
# For each option, a short and long version has to be defined.
# Let's see something more significant
# declare -Ar args_array=( [u]=user [f]=finalpath= [d]=database )
#
# NB: Because we're using 'declare' without -g, the array will be declared as a local variable.
#
# Please keep in mind that the long option will be used as a variable to store the values for this option.
# For the previous example, that means that $finalpath will be fill with the value given as argument for this option.
#
# Also, in the previous example, finalpath has a '=' at the end. That means this option need a value.
# So, the helper has to be call with --finalpath /final/path, --finalpath=/final/path or -f /final/path, the variable $finalpath will get the value /final/path
# If there's many values for an option, -f /final /path, the value will be separated by a ';' $finalpath=/final;/path
# For an option without value, like --user in the example, the helper can be called only with --user or -u. $user will then get the value 1.
#
# To keep a retrocompatibility, a package can still call a helper, using getopts, with positional arguments.
# The "legacy mode" will manage the positional arguments and fill the variable in the same order than they are given in $args_array.
# e.g. for `my_helper "val1" val2`, arg1 will be filled with val1, and arg2 with val2.
ynh_handle_getopts_args () {
	# Manage arguments only if there's some provided
	set +x
	if [ $# -ne 0 ]
	then
		# Store arguments in an array to keep each argument separated
		local arguments=("$@")

		# For each option in the array, reduce to short options for getopts (e.g. for [u]=user, --user will be -u)
		# And built parameters string for getopts
		# ${!args_array[@]} is the list of all keys in the array (A key is 'u' in [u]=user, user is a value)
		local getopts_parameters=""
		local key=""
		for key in "${!args_array[@]}"
		do
			# Concatenate each keys of the array to build the string of arguments for getopts
			# Will looks like 'abcd' for -a -b -c -d
			# If the value of a key finish by =, it's an option with additionnal values. (e.g. --user bob or -u bob)
			# Check the last character of the value associate to the key
			if [ "${args_array[$key]: -1}" = "=" ]
			then
				# For an option with additionnal values, add a ':' after the letter for getopts.
				getopts_parameters="${getopts_parameters}${key}:"
			else
				getopts_parameters="${getopts_parameters}${key}"
			fi
			# Check each argument given to the function
			local arg=""
			# ${#arguments[@]} is the size of the array
			for arg in `seq 0 $(( ${#arguments[@]} - 1 ))`
			do
				# And replace long option (value of the key) by the short option, the key itself
				# (e.g. for [u]=user, --user will be -u)
				# Replace long option with =
				arguments[arg]="${arguments[arg]//--${args_array[$key]}/-${key} }"
				# And long option without =
				arguments[arg]="${arguments[arg]//--${args_array[$key]%=}/-${key}}"
			done
		done

		# Read and parse all the arguments
		# Use a function here, to use standart arguments $@ and be able to use shift.
		parse_arg () {
			# Read all arguments, until no arguments are left
			while [ $# -ne 0 ]
			do
				# Initialize the index of getopts
				OPTIND=1
				# Parse with getopts only if the argument begin by -, that means the argument is an option
				# getopts will fill $parameter with the letter of the option it has read.
				local parameter=""
				getopts ":$getopts_parameters" parameter || true

				if [ "$parameter" = "?" ]
				then
					ynh_die "Invalid argument: -${OPTARG:-}"
				elif [ "$parameter" = ":" ]
				then
					ynh_die "-$OPTARG parameter requires an argument."
				else
					local shift_value=1
					# Use the long option, corresponding to the short option read by getopts, as a variable
					# (e.g. for [u]=user, 'user' will be used as a variable)
					# Also, remove '=' at the end of the long option
					# The variable name will be stored in 'option_var'
					local option_var="${args_array[$parameter]%=}"
					# If this option doesn't take values
					# if there's a '=' at the end of the long option name, this option takes values
					if [ "${args_array[$parameter]: -1}" != "=" ]
					then
						# 'eval ${option_var}' will use the content of 'option_var'
						eval ${option_var}=1
					else
						# Read all other arguments to find multiple value for this option.
						# Load args in a array
						local all_args=("$@")

						# If the first argument is longer than 2 characters,
						# There's a value attached to the option, in the same array cell
						if [ ${#all_args[0]} -gt 2 ]; then
							# Remove the option and the space, so keep only the value itself.
							all_args[0]="${all_args[0]#-${parameter} }"
							# Reduce the value of shift, because the option has been removed manually
							shift_value=$(( shift_value - 1 ))
						fi

						# Then read the array value per value
						for i in `seq 0 $(( ${#all_args[@]} - 1 ))`
						do
							# If this argument is an option, end here.
							if [ "${all_args[$i]:0:1}" == "-" ] || [ -z "${all_args[$i]}" ]
							then
								# Ignore the first value of the array, which is the option itself
								if [ "$i" -ne 0 ]; then
									break
								fi
							else
								# Declare the content of option_var as a variable.
								eval ${option_var}=""
								# Else, add this value to this option
								# Each value will be separated by ';'
								if [ -n "${!option_var}" ]
								then
									# If there's already another value for this option, add a ; before adding the new value
									eval ${option_var}+="\;"
								fi
								eval ${option_var}+=\"${all_args[$i]}\"
								shift_value=$(( shift_value + 1 ))
							fi
						done
					fi
				fi

				# Shift the parameter and its argument(s)
				shift $shift_value
			done
		}

		# LEGACY MODE
		# Check if there's getopts arguments
		if [ "${arguments[0]:0:1}" != "-" ]
		then
			# If not, enter in legacy mode and manage the arguments as positionnal ones.
			echo "! Helper used in legacy mode !"
			for i in `seq 0 $(( ${#arguments[@]} -1 ))`
			do
				# Use getopts_parameters as a list of key of the array args_array
				# Remove all ':' in getopts_parameters
				getopts_parameters=${getopts_parameters//:}
				# Get the key from getopts_parameters, by using the key according to the position of the argument.
				key=${getopts_parameters:$i:1}
				# Use the long option, corresponding to the key, as a variable
				# (e.g. for [u]=user, 'user' will be used as a variable)
				# Also, remove '=' at the end of the long option
				# The variable name will be stored in 'option_var'
				local option_var="${args_array[$key]%=}"

				# Store each value given as argument in the corresponding variable
				# The values will be stored in the same order than $args_array
				eval ${option_var}+=\"${arguments[$i]}\"
			done
		else
			# END LEGACY MODE
			# Call parse_arg and pass the modified list of args as an array of arguments.
			parse_arg "${arguments[@]}"
		fi
	fi
	set -x
}

# Argument $1 is the size of the swap in MiB
ynh_add_swap () {
	# Declare an array to define the options of this helper.
	declare -Ar args_array=( [s]=size= )
	local size
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"

	local swap_max_size=$(( $size * 1024 ))

	local free_space=$(df --output=avail / | sed 1d)
	# Because we don't want to fill the disk with a swap file, divide by 2 the available space.
	local usable_space=$(( $free_space / 2 ))

	# Compare the available space with the size of the swap.
	# And set a acceptable size from the request
	if [ $usable_space -ge $swap_max_size ]
	then
		local swap_size=$swap_max_size
	elif [ $usable_space -ge $(( $swap_max_size / 2 )) ]
	then
		local swap_size=$(( $swap_max_size / 2 ))
	elif [ $usable_space -ge $(( $swap_max_size / 3 )) ]
	then
		local swap_size=$(( $swap_max_size / 3 ))
	elif [ $usable_space -ge $(( $swap_max_size / 4 )) ]
	then
		local swap_size=$(( $swap_max_size / 4 ))
	else
		echo "Not enough space left for a swap file" >&2
		local swap_size=0
	fi

	# If there's enough space for a swap, and no existing swap here
	if [ $swap_size -ne 0 ] && [ ! -e /swap ]
	then
		# Preallocate space for the swap file
		fallocate -l ${swap_size}K /swap
		chmod 0600 /swap
		# Create the swap
		mkswap /swap
		# And activate it
		swapon /swap
		# Then add an entry in fstab to load this swap at each boot.
		echo -e "/swap swap swap defaults 0 0 #Swap added by $app" >> /etc/fstab
	fi
}

ynh_del_swap () {
	# If there a swap at this place
	if [ -e /swap ]
	then
		# Clean the fstab
		sed -i "/#Swap added by $app/d" /etc/fstab
		# Desactive the swap file
		swapoff /swap
		# And remove it
		rm /swap
	fi
}

# Checks the app version to upgrade with the existing app version and returns:
# - UPGRADE_APP if the upstream app version has changed
# - UPGRADE_PACKAGE if only the YunoHost package has changed
#
## It stops the current script without error if the package is up-to-date
#
# This helper should be used to avoid an upgrade of an app, or the upstream part
# of it, when it's not needed
#
# To force an upgrade, even if the package is up to date,
# you have to set the variable YNH_FORCE_UPGRADE before.
# example: sudo YNH_FORCE_UPGRADE=1 yunohost app upgrade MyApp

# usage: ynh_check_app_version_changed
ynh_check_app_version_changed () {
  local force_upgrade=${YNH_FORCE_UPGRADE:-0}
  local package_check=${PACKAGE_CHECK_EXEC:-0}

  # By default, upstream app version has changed
  local return_value="UPGRADE_APP"

  local current_version=$(ynh_read_json "/etc/yunohost/apps/$YNH_APP_INSTANCE_NAME/manifest.json" "version" || echo 1.0)
  local current_upstream_version="${current_version/~ynh*/}"
  local update_version=$(ynh_read_manifest "version" || echo 1.0)
  local update_upstream_version="${update_version/~ynh*/}"

  if [ "$current_version" == "$update_version" ] ; then
      # Complete versions are the same
      if [ "$force_upgrade" != "0" ]
      then
        echo "Upgrade forced by YNH_FORCE_UPGRADE." >&2
        unset YNH_FORCE_UPGRADE
      elif [ "$package_check" != "0" ]
      then
        echo "Upgrade forced for package check." >&2
      else
        ynh_die "Up-to-date, nothing to do" 0
      fi
  elif [ "$current_upstream_version" == "$update_upstream_version" ] ; then
    # Upstream versions are the same, only YunoHost package versions differ
    return_value="UPGRADE_PACKAGE"
  fi
  echo $return_value
}
