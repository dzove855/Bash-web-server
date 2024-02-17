# Bash-web-server
A purely bash web server, no socat, netcat, etc... 

# Requirement
* bash 5.2 (The patch will be included in bash5.2 - Alpha release already contains the patch)
* if bash version is under 5.2, patched loadable accept builtin (http://git.savannah.gnu.org/cgit/bash.git/tree/examples/loadables/accept.c) is needed, you have to apply accept.patch to your loadable accept.c file which is existed in bash source code, and than build and install the loadable accept builtin into BASH_LOADABLE_PATH specified in `bash-server.sh`

# How to
The port can be set by the env var: HTTP_PORT

The path to accept (Directory) can be set by using: BASH_LOADABLES_PATH (see man bash)

Server Methods:
* serveHtml (needs DOCUMENT_ROOT envvars) - This will serve the static files
* script file - The script need a file as first argument which will be source. The file will need a function named runner, which will be run on each request

Basic authentication can be enabled by env var: BASIC_AUTH, accounts and passwords are stored in the file specified in $BASIC_AUTH_FILE


# Usage
Simple explication of various functions that could be used.

## Session Handling
Variables:

```
    SESSION_COOKIE
        The name of the cookie : default BASHSESSID
```

Functions:

```
    sessionStart
        Start a session or reuse an existing session

    sessionSet $1 $2
        Set a session variable

    sessionGet $1 
        Get the value of the given variable
```

## Cookie Handling
Functions:

```
    cookieSet $1 
        Send the cookie
        Example: cookieSet "BASHSESSID=12345; max-age=5000" 
```

## HTTP Handling
Functions:

```
    httpSendStatus $1 
        Send the provided http status
        Example: httpSendStatus 200

    To set Headers, you should add an entry inside the assoc var HTTP_RESPONSE_HEADERS
        HTTP_RESPONSE_HEADERS["ExampleHeader"]="The value of the Header"
```
