runner(){
    case "$REQUEST_PATH" in
        '/index.html')
            cat example/index.html
        ;;
        '/css/main.css')
            cat example/main.css
        ;;
    esac
}
