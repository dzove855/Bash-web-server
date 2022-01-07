#!/usr/bin/bash

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
    IFS='?' read -r _ get <<<"$REQUEST_PATH"
    IFS='&' read -ra data <<<"$get"
    for entry in "${data[@]}"; do
        GET_DATA["${entry%%=*}"]="${entry#*:}"
    done
}

parsePostData(){
    # Split POst data into an assoc if is a form, if not create a key raw
    if [[ "${HTTP_HEADERS["Content-type"]}" == "application/x-www-form-urlencoded" ]]; then
        IFS='&' read -rN "${HTTP_HEADERS["Content-Length"]}" -a data
        for entry in "${data[@]}"; do
            entry="${entry%%$'\r'}"
            POST_DATA["${entry%%=*}"]="${entry#*:}"
        done
    else
        read -rN "${HTTP_HEADERS["Content-Length"]}" data
        POST_DATA["raw"]="${data%%$'\r'}"
    fi
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
    local tmpFile="$(createTemp)"

    # build a default header
    httpSendStatus 200

    runner >"$tmpFile"
    
    buildHttpHeaders
    # From HTTP RFC 2616 send newline before body
    printf "\n"

    printf '%s\n' "$(<$tmpFile)"
    
    # remove tmpfile, this should be trapped...
    # XXX: No needed anymore, since the clean will do the job for use
    # rm "$tmpFile"
}

parseAndPrint(){

    # Parse Request
    parseHttpRequest

    # Create headers assoc
    parseHttpHeaders

    # Parse Get Data
    parseGetData

    # Parse post data only if length is > 0 and post is specified
    if [[ "$REQUEST_METHOD" == "POST" ]] && (( ${HTTP_HEADERS['Content-Length']} > 0 )); then
        parsePostData
    fi

    buildResponse
}

createTemp(){
    # Provide a wrapper of mktemp to store it inside an array and remove all tmpfiles on exit
    # no need to provide TMPDIR, since mktemp does it auotmatically

    # XXX: The builtin mktemp allows the usage of option -v VARNAME, this would be a much better use case..
    #       But we don't want to annoy everyone who doesn't provide the builtin
    local tmpfile="$(mktemp bash-server.XXXXXX)"
    tmpFiles+=("$tmpfile")
    printf '%s' "$tmpfile"
}

clean(){
    [[ -z "${tmpFiles[*]}" ]] || rm "${tmpFiles[*]}"
}

main(){

    : "${BASH_LOADABLE_PATH:=/usr/lib/bash}"
    if ! [[ -f "${BASH_LOADABLE_PATH%/}/accept" ]]; then
        printf '%s\n' "Cannot load accept..."
        exit 1
    fi

    
    # Enable mktemp and rm as a builtin :D
    # Don't fail if it doesn't exist
    enable -f "${BASH_LOADABLE_PATH%/}/mktemp"  mktemp  &>/dev/null || true
    enable -f "${BASH_LOADABLE_PATH%/}/rm"      rm      &>/dev/null || true

    enable -f "${BASH_LOADABLE_PATH%/}/accept" accept

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

    trap 'clean' EXIT
    while :; do

        # We will alway reset all variables and build them again
        local REQUEST_METHOD REQUEST_PATH HTTP_VERSION
        local -A HTTP_HEADERS
        local -A POST_DATA
        local -A GET_DATA
        local -A HTTP_RESPONSE_HEADERS
        local -a tmpFiles

        # XXX: Accept puts the connection in a TIME_WAIT status.. :(
        # Verifiy if bind_address is specified default to 127.0.0.1
        # You should use the custom accept in order to use bind address and multiple connections
        : "${BIND_ADDRESS:=127.0.0.1}"
        if [[ "${BIND_ADDRESS}" == "0.0.0.0" ]]; then
            accept "${HTTP_PORT:-8080}" || {
                printf '%s\n' "Could not listen on 0.0.0.0:${HTTP_PORT:-8080}"
                exit 1
            }
        else
            accept -b "${BIND_ADDRESS}" "${HTTP_PORT:-8080}" || {
                printf '%s\n' "Could not listen on 0.0.0.0:${HTTP_PORT:-8080}"
                exit 1
            }
        fi

        parseAndPrint <&${ACCEPT_FD} >&${ACCEPT_FD}
        
        # XXX: This is needed to close the connection to the client
        # XXX: Currently no other way found around it.. :(

        exec {ACCEPT_FD}<&-
        exec {ACCEPT_FD}>&-


        # Clean tmpfiles
        clean
        # Unset all vars
        unset REQUEST_METHOD REQUEST_PATH HTTP_VERSION HTTP_HEADERS POST_DATA GET_DATA HTTP_RESPONSE_HEADERS tmpFiles

        sleep "${TIME_WAIT:-0}"
    done
    
}

main "$@" 

