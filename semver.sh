#/usr/bin/env sh

_num_part='([0-9]|[1-9][0-9]*)'
_lab_part='([0-9]|[1-9][0-9]*|[0-9]*[a-zA-Z-][a-zA-Z0-9-]*)'
_met_part='([0-9A-Za-z-]+)'

RE_NUM="$_num_part(\.$_num_part)*"
RE_LAB="$_lab_part(\.$_lab_part)*"
RE_MET="$_met_part(\.$_met_part)*"
RE_VER="[ \t]*$RE_NUM(-$RE_LAB)?(\+$RE_MET)?"

BRE_NUM='[0-9]\{1,\}\(\.[0-9]\{1,\}\)*'
BRE_PRE='[0-9a-zA-Z-]\{1,\}\(\.[0-9a-zA-Z-]\{1,\}\)*'
BRE_MET='[0-9A-Za-z-]\{1,\}'
BRE_VER="$BRE_NUM\(-$BRE_PRE\)\{0,1\}\(+$BRE_MET\)\{0,1\}"

filter()
{
    local text="$1"
    local regex="$2"
    shift 2
    echo "$text" | grep -E $@ "$regex"
}

# Gets number part from normalized version
get_number()
{
    echo ${1%%-*}
}

# Gets prerelase part from normalized version
get_prerelease()
{
    pre_and_meta=${1%+*}
    pre=${pre_and_meta#*-}
    if [ "$pre" = "$1" ]; then
        echo
    else
        echo $pre
    fi
}

# Gets major number from normalized version
get_major()
{
    echo ${1%%.*}
}

# Gets minor number from normalized version
get_minor()
{
    minor=$(echo "$1." | cut -d '.' -f 2)

    if [ -z "$minor" ]; then
        echo -n 0
    else
        echo -n $minor
    fi
}

get_bugfix()
{
    bugfix=$(echo "$1." | cut -d '.' -f 3)

    if [ -z "$bugfix" ]; then
        echo -n 0
    else
        echo -n $bugfix
    fi
}

strip_metadata()
{
    echo ${1%+*}
}

semver_eq()
{
    local ver1=$(get_number $1)
    local ver2=$(get_number $2)

    local count=1
    while true; do
        local part1=$(echo $ver1'.' | cut -d '.' -f $count)
        local part2=$(echo $ver2'.' | cut -d '.' -f $count)

        if [ -z "$part1" ] || [ -z "$part2" ]; then
            break
        fi

        if [ "$part1" != "$part2" ]; then
            return 1
        fi

        local count=$(( count + 1 ))
    done

    return 0
}

semver_lt()
{
    local number_a=$(get_number $1)
    local number_b=$(get_number $2)
    local labels_a=$(get_labels $1)
    local labels_b=$(get_labels $2)

    local head_a=''
    local head_b=''
    local rest_a=$number_a
    local rest_b=$number_b
    while [ -n "$rest_a" ] || [ -n "$rest_b" ]; do
        head_a=${rest_a%%.*}
        head_b=${rest_b%%.*}
        rest_a=${rest_a#*.}
        rest_b=${rest_b#*.}
        [ "$rest_a" = "$head_a" ] && rest_a=''
        [ "$rest_b" = "$head_b" ] && rest_b=''
        [ -z "$head_a" ] && head_a=0
        [ -z "$head_b" ] && head_b=0

        if [ "$head_a" -eq "$head_b" ]; then
            continue
        fi

        if [ "$head_a" -lt "$head_b" ]; then
            return 0
        else
            return 1
        fi
    done

    if [ -n "$labels_a" ] && [ -z "$labels_b" ]; then
        return 0
    fi

    return 1
}

semver_gt()
{
    if semver_lt "$1" "$2" || semver_eq "$1" "$2"; then
        return 1
    else
        return 0
    fi
}

semver_le()
{
    semver_gt "$1" "$2" && return 1 || return 0
}

semver_ge()
{
    semver_lt "$1" "$2" && return 1 || return 0
}

regex_match()
{
    local string="$1 "
    local regexp="$2"
    local match="$(eval "echo '$string' | grep -E -o '^[ \t]*($regexp)[ \t]+'")";

    for i in $(seq 0 9); do
        unset "MATCHED_VER_$i"
        unset "MATCHED_NUM_$i"
    done
    unset REST

    if [ -z "$match" ]; then
        return 1
    fi

    local match_len=$(echo "$match" | wc -c)
    REST=`echo "$string" | cut -c $match_len-`

    local part
    local i=1
    for part in $(echo $string); do
        local ver="$(eval "echo '$part' | grep -E -o '$RE_VER'   | head -n 1 | sed 's/ \t//g'")";
        local num=$(get_number "$ver")

        if [ -n "$ver" ]; then
            eval "MATCHED_VER_$i='$ver'"
            eval "MATCHED_NUM_$i='$num'"
            i=$(( i + 1 ))
        fi
    done

    return 0
}

# Normalizes rules string
#
# * replaces chains of whitespaces with single spaces
# * replaces whitespaces around hyphen operator with "_"
# * replaces "x" with "*"
# * removes whitespace between operators and version numbers
# * removes leading "v" from version numbers
# * removes leading and trailing spaces
normalize_rules()
{
    echo " $1" \
        | sed 's/\t/ /g' \
        | sed 's/ \{2,\}/ /g' \
        | sed 's/ - /_-_/g' \
        | sed 's/\([~^<>=]\) /\1/g' \
        | sed 's/\([ _~^<>=]\)v/\1/g' \
        | sed 's/x/*/g' \
        | sed 's/^ //g' \
        | sed 's/ $//g'
}

# Reads rule from provided string
read_rule()
{
    RULEIND=$(( $RULEIND + 1 ))

    local _rule="$( echo "$1 " | cut -d ' ' -f $RULEIND  )"
    local _idnt="$( echo "$_rule" | sed "s/$BRE_VER/#/g" )"
    local _vers="$( echo "$_rule" | grep -o "$BRE_VER"   )"

    # if rule is empty - there is no more rules
    if [ -z "$_rule" ]; then
        return 1
    fi

    local _i=1;
    for ver in `echo $_vers`; do
        eval "RULEVER_$_i='$ver'"
        _i=$(( $_i + 1 ))
    done

    # set global variable
    eval "$2='$_idnt'"
}

resolve_rule()
{
    RULEIND=0

    local rules="$(normalize_rules "$1")"
    local output=""

    while read_rule "$rules" rule; do
        case "$rule" in
            '*')     echo ge 0.0.0-0;;
            '#')     echo eq $RULEVER_1;;
            '<#')    echo lt $RULEVER_1;;
            '>#')    echo gt $RULEVER_1;;
            '<=#')   echo le $RULEVER_1;;
            '>=#')   echo ge $RULEVER_1;;
            '#_-_#') echo ge $RULEVER_1
                     echo le $RULEVER_2;;
            #'~#')    echo tilde;;
            #'^#')    echo caret;;
            '#.*')   echo eq $RULEVER_1;;
            '#.*.*') echo eq $RULEVER_1;;
            *)       return 1
        esac
    done
}

rule_eq()
{
    semver_eq $2 $1 && return 0 || return 1;
}

rule_le()
{
    semver_le $2 $1 && return 0 || return 1;
}

rule_lt()
{
    semver_lt $2 "$1" && return 0 || return 1;
}

rule_ge()
{
    semver_ge $2 $1 && return 0 || return 1;
}

rule_gt()
{
    semver_gt $2 $1 && return 0 || return 1;
}

if [ $# -eq 0 ]; then
    echo "Usage:    $0 -r <rule> <version> [<version>... ]"
fi

while getopts r:h o; do
    case "$o" in
        r) rules_string="$OPTARG||";;
        h|?) echo "Usage:    $0 -r <rule> <version> [<version>... ]"
    esac
done

shift $(( $OPTIND-1 ))

while [ -n "$rules_string" ]; do
    head="${rules_string%%||*}"

    if [ "$head" = "$rules_string" ]; then
        rules_string=""
    else
        rules_string="${rules_string#*||}"
    fi

    if [ -z "$head" ] || [ -n "$(echo "$head" | grep -E -x '[ \t]*')" ]; then
        group=$(( $group + 1 ))
        continue
    fi

    rules="$(resolve_rule "$head")"

    if [ $? -eq 1 ]; then
        exit
    fi

    for ver in $@; do
        if [ -z `echo "$ver" | grep -E -x "[v=]?[ \t]*$RE_VER"` ]; then
            continue
        fi

        ver=`echo "$ver" | grep -E -x "$RE_VER"`

        success=true
        while read -r rule; do
            rule_$rule "$ver"
            if [ $? -eq 1 ]; then
                success=false
                break
            fi
        done \
<<EOF
$rules
EOF

        if $success; then
            if [ -z "$max" ] || semver_lt "$max" "$ver"; then
                max="$ver"
            fi
        fi
    done

    group=$(( $group + 1 ))
done

if [ -n "$max" ]; then
    echo $max
fi
