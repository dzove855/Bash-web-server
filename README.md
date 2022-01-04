# Bash-web-server
A purely bash web server, no socat, netcat, etc... 

# Requirement
* bash 5.1
* loadable accept builtin (http://git.savannah.gnu.org/cgit/bash.git/tree/examples/loadables/accept.c)

# How to
The port can be set by the env var: HTTP_PORT
The path to accept (Directory) can be set by using: BASH_LOADABLE_PATH

The scripts need a file as first argument which will be source. The file will need a function named runner, which will be run on each request

# Problems...
Well there's a little problem... since accept doesn't close the connection (Or i'm doing something wrong), the connection will go into TIME_WAIT.
This means that we need to wait the time the connection will be closed, after that we can reopen a connection. 
I will have a look at te source code and probably provide some options, like a bind-address and a close when the FD is closed.
