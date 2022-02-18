#!/usr/local/bin/bash

# https://github.com/dylanaraps/pure-bash-bible#decode-a-percent-encoded-string
urldecode() {
    : "${1//+/ }"
    printf '%b\n' "${_//%/\\x}"
}

parseHttpRequest(){
    # Get information about the request
    read -r REQUEST_METHOD REQUEST_PATH HTTP_VERSION
    HTTP_VERSION="${HTTP_VERSION%%$'\r'}"
}

parseHttpHeaders(){
    # Split headers and put it inside HTTP_HEADERS, so it can be reused
    while read -r line; do
        line="${line%%$'\r'}"

        [[ -z "$line" ]] && return
        HTTP_HEADERS["${line%%:*}"]="${line#*:}" 
    done
}

parseGetData(){
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
    printf '%s %s\n' "$HTTP_VERSION" "${HTTP_RESPONSE_HEADERS['status']}"
    unset HTTP_RESPONSE_HEADERS['status']

    for key in "${!HTTP_RESPONSE_HEADERS[@]}"; do
        printf '%s: %s\n' "$key" "${HTTP_RESPONSE_HEADERS[$key]}"
    done 
}

buildResponse(){
    # Every output will first be saved in a file and then printed to the output
    # Like this we can build a clean output to the client

    # build a default header
    httpSendStatus 200

    # get mime type
    IFS=. read -r _ extension <<<"$REQUEST_PATH"
    [[ -z "${MIME_TYPES["${extension:-html}"]}" ]] || HTTP_RESPONSE_HEADERS["Content-Type"]="${MIME_TYPES["${extension:-html}"]}"

    "$run" >"$TMPDIR/output"

    # get content-legth 
    PATH="" type -p "finfo" &>/dev/null && HTTP_RESPONSE_HEADERS["Content-Length"]="$(finfo -s $TMPDIR/output)"

    # print output to logfile
    (( LOGGING )) && logPrint

    buildHttpHeaders
    # From HTTP RFC 2616 send newline before body
    printf "\n"

    printf '%s\n' "$(<$TMPDIR/output)"
    
    # remove tmpfile, this should be trapped...
    # XXX: No needed anymore, since the clean will do the job for use
    # rm "$tmpFile"
}

parseAndPrint(){
    # We will alway reset all variables and build them again
    local REQUEST_METHOD REQUEST_PATH HTTP_VERSION QUERY_STRING
    local -A HTTP_HEADERS
    local -A POST
    local -A GET
    local -A HTTP_RESPONSE_HEADERS
    local -A COOKIE

    # Now mktemp will write create files inside the temporary directory
    local -r TMPDIR="$serverTmpDir"

    # Parse Request
    parseHttpRequest

    # Create headers assoc
    parseHttpHeaders

    # Parse Get Data
    parseGetData

    # Parse cookie data
    parseCookieData

    # Parse post data only if length is > 0 and post is specified
    # bash (( will not fail if var is not a number, it will just return 1, no need of int check
    if [[ "$REQUEST_METHOD" == "POST" ]] && (( ${HTTP_HEADERS['Content-Length']} > 0 )); then
        parsePostData
    fi

    buildResponse
}

serveHtml(){
    if [[ ! -z "$DOCUMENT_ROOT" ]]; then
        DOCUMENT_ROOT="${DOCUMENT_ROOT%/}"

        # Don't allow going out of DOCUMENT_ROOT
        case "$DOCUMENT_ROOT" in
            *".."*|*"~"*)
                httpSendStatus 404
                printf '404 Page Not Found!\n'
                return
            ;;
        esac
        [[ "$REQUEST_PATH" == "/" ]] && REQUEST_PATH="/index.html"
        if [[ -f "$DOCUMENT_ROOT/${REQUEST_PATH#/}" ]]; then
            printf '%s\n' "$(<$DOCUMENT_ROOT/${REQUEST_PATH#/})"
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
    logformat["%T"]="$(( $(printf '%(%s)T' -1 ) - $TIME_SECONDS))"
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

main(){

    local -A MIME_TYPES

    : "${BASH_LOADABLE_PATH:=/usr/lib/bash}"
    : "${HTTP_PORT:=8080}"
    : "${BIND_ADDRESS:=127.0.0.1}"
    : "${MIME_TYPES_FILE:=./mime.types}"
    : "${TMPDIR:=/tmp}"
    : "${LOGFORMAT:="[%t] - %a %m %U %s %b %T"}"
    : "${LOGFILE:=access.log}"
    : "${LOGGING:=1}"
    TMPDIR="${TMPDIR%/}"

    ! [[ ${BIND_ADDRESS} == "0.0.0.0" ]] && acceptArg="-b ${BIND_ADDRESS}"

    if ! [[ -f "${BASH_LOADABLE_PATH%/}/accept" ]]; then
        printf '%s\n' "Cannot load accept..."
        exit 1
    fi

    [[ -f "$MIME_TYPES_FILE" ]] && \
        while read -r types extension; do
            read -a extensions <<<"$extension"
            for ext in "${extensions[@]}"; do
                MIME_TYPES["$ext"]="$types"
            done
        done <"$MIME_TYPES_FILE"

    
    # Enable mktemp and rm as a builtin :D
    # Don't fail if it doesn't exist
    enable -f "${BASH_LOADABLE_PATH%/}/mktemp"  mktemp  &>/dev/null || true
    enable -f "${BASH_LOADABLE_PATH%/}/rm"      rm      &>/dev/null || true
    enable -f "${BASH_LOADABLE_PATH%/}/finfo"   finfo   &>/dev/null || true

    enable -f "${BASH_LOADABLE_PATH%/}/accept" accept || {
        printf '%s\n' "Could not load accept..."
        exit 1
    }
 
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

        until [[ -s "$serverTmpDir/spawnNewProcess" || ! -f "$serverTmpDir/spawnNewProcess" ]]; do : ; done

        # Since the patch, no need of sleep anymore
        #sleep "${TIME_WAIT:-0}"
    done
    
}

main "$@" 
