# Bash-web-server
A purely bash web server, no socat, netcat, etc... 

# Requirement
* bash 5.2 (The patch will be included in bash5.2 - Alpha release already contains the patch)
* if bash version is under 5.2, patched loadable accept builtin (http://git.savannah.gnu.org/cgit/bash.git/tree/examples/loadables/accept.c) is needed, you have to apply accept.patch to your loadable accept.c file which is existed in bash source code, and than build and install the loadable accept builtin into BASH_LOADABLE_PATH specified in `bash-server.sh`

# How to
The port can be set by the env var: HTTP_PORT

The path to accept (Directory) can be set by using: BASH_LOADABLE_PATH

Server Methods:
* serveHtml (needs DOCUMENT_ROOT envvars) - This will serve the static files
* script file - The script need a file as first argument which will be source. The file will need a function named runner, which will be run on each request

Basic authentication can be enabled by env var: NEED_AUTH, accounts and passwords are stored in users.csv

# Problems...
Well there's a little problem... since accept doesn't close the connection (Or i'm doing something wrong), the connection will go into TIME_WAIT.
This means that we need to wait the time the connection will be closed, after that we can reopen a connection. 
I will have a look at the source code and probably provide some options, like a bind-address and a close when the FD is closed.

### UPDATE:
Accept has been patched by me. Now we can handle multiple request at the same time, without waiting the TIME_WAIT. 

To use the new accept, you will need to compile the accept from this repo, a pull request will be send to bash, but it will take some time.

Now we can run multiple connection on the same time, since the connection is running in a subshell.

# Busion
Busion is used to source some functions from other repositorys instead of copy/paste (https://github.com/dzove855/busion)

# TODO
- [X] Implement logging and provide a logging format like httpd
- [X] Implement multi processing (this will be a huge step, but we need to patch accept)
- [X] Implement urlencode/decode to provide readable get data
- [X] Implement content-type detection - Use mime type like nginx
- [X] Add basic auth
- [X] Add cookie handler
- [ ] Add session handler
