#!/usr/local/bin/bash

# https://github.com/dylanaraps/pure-bash-bible#decode-a-percent-encoded-string
urldecode() {
    : "${1//+/ }"
    printf '%b\n' "${_//%/\\x}"
}

# https://gist.github.com/markusfisch/6110640
uuidgen() {
    local N B C='89ab'

    for (( N=0; N < 16; ++N )); do
        B="$(( RANDOM%256 ))"

        case $N in
        6)
            printf '4%x' $(( B%16 ))
        ;;
        8)
            printf '%c%x' ${C:$RANDOM%${#C}:1} $(( B%16 ))
        ;;
        3 | 5 | 7 | 9)
            printf '%02x-' $B
        ;;
        *)
            printf '%02x' $B
        ;;
        esac
    done
}

send_encoded_frame() {
    local first_byte="0x81"
    local hex_string binary

# TODO: Get this working!
#    printf -v 'hex_string' '%s0x%x' "$first_byte" "${#1}"    
#    for ((i = 0; i < ${#hex_string}; i += 2)); do
#        binary+="\x${hex_string:i:2}"
#    done
#    _verbose 4 "$binary"

    printf '%s0x%x' $first_byte "${#1}" | xxd -r -p    
    printf '%s' "$1"
}

parseHttpRequest(){
    # Get information about the request
    read -r REQUEST_METHOD REQUEST_PATH HTTP_VERSION
    HTTP_VERSION="${HTTP_VERSION%%$'\r'}"
}

parseHttpHeaders(){
    local line _h _v
    # Split headers and put it inside HTTP_HEADERS, so it can be reused
    while read -r line; do
        line="${line%%$'\r'}"
        _verbose 3 "$line"
        [[ -z "$line" ]] && return
        _h="${line%%:*}"
        HTTP_HEADERS["${_h,,}"]="${line#*: }" 
    done
}

parseGetData(){
    local entry
    # Split QUERY_STRING into an assoc, so it can be easy reused
    IFS='?' read -r REQUEST_PATH get <<<"$REQUEST_PATH"

    # Url decode get data
    get="$(urldecode "$get")"

    # Split html #
    IFS='#' read -r REQUEST_PATH _ <<<"$REQUEST_PATH"
    QUERY_STRING="$get"
    IFS='&' read -ra data <<<"$get"
    for entry in "${data[@]}"; do
        GET["${entry%%=*}"]="${entry#*:}"
    done
}

parsePostData(){
    local entry
    # Split POst data into an assoc if is a form, if not create a key raw
    if [[ "${HTTP_HEADERS["Content-type"]}" == "application/x-www-form-urlencoded" ]]; then
        IFS='&' read -rN "${HTTP_HEADERS["Content-Length"]}" -a data
        for entry in "${data[@]}"; do
            entry="${entry%%$'\r'}"
            POST["${entry%%=*}"]="${entry#*:}"
        done
    else
        read -rN "${HTTP_HEADERS["Content-Length"]}" data
        POST["raw"]="${data%%$'\r'}"
    fi
}

parseCookieData(){
    local -a cookie
    local entry key value
    IFS=';' read -ra cookie <<<"${HTTP_HEADERS["Cookie"]}"

    for entry in "${cookie[@]}"; do
        IFS='=' read -r key value <<<"$entry"
        COOKIE["${key# }"]="${value% }"
    done
}

httpSendStatus(){
    local -A status_code=(
        [101]="101 Switching Protocols"
        [200]="200 OK"
        [201]="201 Created"
        [301]="301 Moved Permanently"
        [302]="302 Found"
        [400]="400 Bad Request"
        [401]="401 Unauthorized"
        [403]="403 Forbidden"
        [404]="404 Not Found"
        [405]="405 Method Not Allowed"
        [500]="500 Internal Server Error"
    )

    HTTP_RESPONSE_HEADERS['status']="${status_code[${1:-200}]}"
}

buildHttpHeaders(){
    # We will first send the status header and then all the other headers
    _verbose 2 "status ${HTTP_RESPONSE_HEADERS['status']}"
    printf '%s %s\n' "$HTTP_VERSION" "${HTTP_RESPONSE_HEADERS['status']}"
    unset 'HTTP_RESPONSE_HEADERS["status"]'

    _verbose 2 "${cookie_to_send}"

    for value in "${cookie_to_send[@]}"; do
        printf 'Set-Cookie: %s\n' "$value"
    done

    for key in "${!HTTP_RESPONSE_HEADERS[@]}"; do
        _verbose 2 "${key,,}: ${HTTP_RESPONSE_HEADERS[$key]}"
        printf '%s: %s\n' "${key,,}" "${HTTP_RESPONSE_HEADERS[$key]}"
    done 
}

websocketStart(){
    websocketStart=1
    websocketRunner="$1"
}

websocketStop(){
    websocketStop=1
}

buildResponse(){
    # Every output will first be saved in a file and then printed to the output
    # Like this we can build a clean output to the client

    local websocketStart websocketRunner websocketStop sha1
    websocketStart=0
    websocketStop=0

    # build a default header
    httpSendStatus "$1"

    [[ $1 == 401 ]] && \
    {
        HTTP_RESPONSE_HEADERS['WWW-Authenticate']="Basic realm=WebServer"
        buildHttpHeaders
        return
    }

    # get mime type
    IFS=. read -r _ extension <<<"$REQUEST_PATH"
    [[ -z "${MIME_TYPES["${extension:-html}"]}" ]] || HTTP_RESPONSE_HEADERS["content-type"]="${MIME_TYPES["${extension:-html}"]}"

    "$run" >"$TMPDIR/output"

    # get content-legth 
    PATH="" type -p "finfo" &>/dev/null && HTTP_RESPONSE_HEADERS["content-length"]="$(finfo -s "$TMPDIR/output")"

    if (( websocketStart )); then
        httpSendStatus 101
        HTTP_RESPONSE_HEADERS['upgrade']="${HTTP_HEADERS['upgrade']}"
        HTTP_RESPONSE_HEADERS['connection']="upgrade"
        read -r sha1 _ <<<"$(printf '%s' "${HTTP_HEADERS['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" | openssl dgst -binary -sha1 | base64)"
        HTTP_RESPONSE_HEADERS['sec-websocket-accept']="$sha1"
        unset "HTTP_RESPONSE_HEADERS['content-length']"
        unset "HTTP_RESPONSE_HEADERS['content-type']"
    fi

    # print output to logfile
    (( LOGGING )) && logPrint

    buildHttpHeaders
    # From HTTP RFC 2616 send newline before body
    printf "\n"

    (( websocketStart )) || printf '%s\n' "$(<"$TMPDIR/output")"
    
    # remove tmpfile, this should be trapped...
    # XXX: No needed anymore, since the clean will do the job for use
    # rm "$tmpFile"

    if (( websocketStart )); then
        _verbose 4 "Websocket Upgrade - $websocketRunner"
        local websocketStop
        websocketStop=0
        sleep 3
        while true; do
            "$websocketRunner" > "$TMPDIR/output"
            message="$(<"$TMPDIR/output")"
            send_encoded_frame "$message"
#            encode_message "$message"
            sleep 5
            (( websocketStop )) && break
        done
    fi

}

parseAndPrint(){
    # We will alway reset all variables and build them again
    local REQUEST_METHOD REQUEST_PATH HTTP_VERSION QUERY_STRING
    local -A HTTP_HEADERS
    local -A POST
    local -A GET
    local -A HTTP_RESPONSE_HEADERS
    local -A COOKIE
    local -A SESSION
    local -a cookie_to_send

    # Now mktemp will write create files inside the temporary directory
    local -r TMPDIR="$serverTmpDir"

    # Parse Request
    parseHttpRequest

    # Create headers assoc
    parseHttpHeaders

    # Basic Auth
    if (( BASIC_AUTH )) then
        basicAuth || return 1
    fi

    # Parse Get Data
    parseGetData

    # Parse cookie data
    parseCookieData


    if [[ -z "${COOKIE["$SESSION_COOKIE"]}" ]] || [[ "${COOKIE["$SESSION_COOKIE"]}" == *..* ]]; then
        SESSION_ID="$(uuidgen)"
    else
        SESSION_ID="${COOKIE["$SESSION_COOKIE"]}"
    fi
    # Parse post data only if length is > 0 and post is specified
    # bash (( will not fail if var is not a number, it will just return 1, no need of int check
    if [[ "$REQUEST_METHOD" == "POST" ]] && (( ${HTTP_HEADERS['Content-Length']} > 0 )); then
        parsePostData
    fi

    buildResponse 200
}

basicAuth(){
    local authData
    local user password 

    [[ -f "$BASIC_AUTH_FILE" ]] || {
        _verbose 1 "Missing \$BASIC_AUTH_FILE"
        return 1
    }

    if [[ -z "${HTTP_HEADERS["Authorization"]}" ]]; then
        buildResponse 401
        return 0
    fi

    # Decode auth data
    # TODO: implement base64 in bash
    authData="$(base64 -d <<<"${HTTP_HEADERS["Authorization"]# Basic }")"

    # Split auth data into user and password
    IFS=: read -r user password <<<"$authData"

    # Check if user and password appear in users.csv
    while read -r r_user r_password; do
        [[ "$r_user" == "$user" && "$r_password" == "$password" ]] && {
            return
        }
    done < "$BASIC_AUTH_FILE"

    buildResponse 401
    return 1
}

sessionStart(){
    [[ -d "${SESSION_PATH}" ]] || {
        _verbose 1 "Missing Session Path \$SESSION_PATH"
        return 1
    }

    if [[ -f "${SESSION_PATH}/$SESSION_ID" ]]; then
        return 0
    else
        cookieSet "$SESSION_COOKIE=$SESSION_ID; max-age=5000"
        return 1
    fi
}

sessionGet(){
    sessionStart && {
        source "${SESSION_PATH}/$SESSION_ID"
        printf '%s' "${SESSION[$1]}"
    }
}

sessionSet(){
    sessionStart && source "${SESSION_PATH}/$SESSION_ID"
    SESSION["$1"]="$2"
    declare -p SESSION > "${SESSION_PATH}/$SESSION_ID"
}

cookieSet(){
    _verbose 2 "$1"
    cookie_to_send+=("$1")
}

serveHtml(){
    if [[ -n "$DOCUMENT_ROOT" ]]; then
        DOCUMENT_ROOT="${DOCUMENT_ROOT%/}"

        # Don't allow going out of DOCUMENT_ROOT
        case "$REQUEST_PATH" in
            *".."*|*"~"*)
                httpSendStatus 404
                printf '404 Page Not Found!\n'
                return
            ;;
        esac
        [[ "$REQUEST_PATH" == "/" ]] && REQUEST_PATH="/index.html"
        if [[ -f "$DOCUMENT_ROOT/${REQUEST_PATH#/}" ]]; then
            printf '%s\n' "$(<"$DOCUMENT_ROOT/${REQUEST_PATH#/}")"
        else
            httpSendStatus 404
            printf '404 Page Not Found!\n'
        fi
    else
        httpSendStatus 404
        printf '404 Page Not Found!\n'
    fi
}

logPrint(){
    local -A logformat
    local output="${LOGFORMAT}"    

    logformat["%a"]="$RHOST"
    logformat["%A"]="${BIND_ADDRESS}"
    logformat["%b"]="${HTTP_RESPONSE_HEADERS["Content-Length"]}"
    logformat["%m"]="$REQUEST_METHOD"
    logformat["%q"]="$QUERY_STRING"
    logformat["%t"]="$TIME_FORMATTED"
    logformat["%s"]="${HTTP_RESPONSE_HEADERS['status']%% *}"
    logformat["%T"]="$(( $(printf '%(%s)T' -1 ) - TIME_SECONDS))"
    logformat["%U"]="$REQUEST_PATH"
    

    for key in "${!logformat[@]}"; do
        output="${output//"$key"/"${logformat[$key]}"}"
    done

    printf '%s\n' "$output" >> "$LOGFILE"
}

_verbose(){
    # This function should be a simple debug function, which will print the line given based on debug level
    # implement in getops the following line:
    # (( DEBUG_LEVEL++))
    local LEVEL=1 c printout
    local funcnamenumber
    (( funcnamenumber=${#FUNCNAME[@]} - 2 ))
    : "${DEBUG_LEVEL:=0}"
    (( DEBUG_LEVEL == 0 )) && return
    # Add level 1 if first char is not set a number
    [[ "$1" =~ ^[0-9]$ ]] && { LEVEL=$1; shift; }

    (( LEVEL <= DEBUG_LEVEL )) && {
        until (( ${#c} == LEVEL )); do c+=":"; done
        if (( funcnamenumber > 0 )); then
            printout+="("
            for ((i=1;i<=funcnamenumber;i++)); do
                printout+="${FUNCNAME[$i]} <- "
            done
            printout="${printout% <- }) - "
        fi
        printf '%-7s %s %s\n' "+ $c" "$printout" "$*" 1>&2
    }
}

clean(){
    kill -9 "$_pid"
}

main(){

    local -A MIME_TYPES

    : "${HTTP_PORT:=8080}"
    : "${BIND_ADDRESS:=127.0.0.1}"
    : "${MIME_TYPES_FILE:=./mime.types}"
    : "${TMPDIR:=/tmp}"
    : "${LOGFORMAT:="[%t] - %a %m %U %s %b %T"}"
    : "${LOGFILE:=access.log}"
    : "${LOGGING:=1}"
    : "${SESSION_COOKIE:=BASHSESSID}"
    : "${BASIC_AUTH:=0}"
    TMPDIR="${TMPDIR%/}"

    ! [[ ${BIND_ADDRESS} == "0.0.0.0" ]] && acceptArg="-b ${BIND_ADDRESS}"

    enable -f accept accept || {
        printf '%s\n' "Cannot load accept..."
        exit 1
    }

    [[ -f "$MIME_TYPES_FILE" ]] && \
        while read -r types extension; do
            read -ra extensions <<<"$extension"
            for ext in "${extensions[@]}"; do
                MIME_TYPES["$ext"]="$types"
            done
        done <"$MIME_TYPES_FILE"

    
    # Enable mktemp and rm as a builtin :D
    # Don't fail if it doesn't exist
    enable -f "mktemp"  mktemp  &>/dev/null || true
    enable -f "rm"      rm      &>/dev/null || true
    enable -f "finfo"   finfo   &>/dev/null || true
 
    trap clean EXIT

    case "$1" in
        serveHtml)
            run="serveHtml"
        ;;
        *)
            # source the configuration file and check if runner is defined
            [[ -z "$1" || ! -f "$1" ]] && {
                printf '%s\n' "please provide a file to source as the first argument..."
                exit 1
            }
            # source main file
            source "$1"
            type runner &>/dev/null || {
                printf '%s\n' "The source file need a function nammed runner which will be executed on each request..."
                exit 1
            }
            run="runner"
        ;;
    esac

    while :; do
	
        # create temporary directory for each request
        _verbose 1 "Listening on $BIND_ADDRESS port $HTTP_PORT"

        serverTmpDir="$(mktemp -d)"
        # Create the file, but do not zrite inside
        : > "$serverTmpDir/spawnNewProcess"

        (
            # XXX: Accept puts the connection in a TIME_WAIT status.. :(
            # Verifiy if bind_address is specified default to 127.0.0.1
            # You should use the custom accept in order to use bind address and multiple connections
            accept $acceptArg "${HTTP_PORT}" || {
                printf '%s\n' "Could not listen on ${BIND_ADDRESS}:${HTTP_PORT}"
                exit 1
            }

            printf '1' > "$serverTmpDir/spawnNewProcess"
            printf -v TIME_FORMATTED '%(%d/%b/%Y:%H:%M:%S)T' -1
            printf -v TIME_SECONDS '%(%s)T' -1
            parseAndPrint <&${ACCEPT_FD} >&${ACCEPT_FD}

            # XXX: This is needed to close the connection to the client
            # XXX: Currently no other way found around it.. :(
            exec {ACCEPT_FD}>&-

            # remove the temporary directoru
            rm -rf "$serverTmpDir"
        ) & 

        _pid="$!"

        until [[ -s "$serverTmpDir/spawnNewProcess" || ! -f "$serverTmpDir/spawnNewProcess" ]]; do : ; done

        # Since the patch, no need of sleep anymore
        #sleep "${TIME_WAIT:-0}"
    done
    
}

main "$@" 
