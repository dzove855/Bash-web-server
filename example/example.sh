runner(){
    if [[ $REQUEST_PATH == "/1" ]]; then
    echo "it's working"
    sleep 5
    echo "10"
    else
	echo cool
    fi
}
