package protocol

import (
	"encoding/gob"
	"io"
)

// Send gob-encodes msg and writes it to w.
func Send(w io.Writer, msg interface{}) error {
	return gob.NewEncoder(w).Encode(&msg)
}

// Receive reads a gob-encoded message from r.
func Receive(r io.Reader) (interface{}, error) {
	var msg interface{}
	err := gob.NewDecoder(r).Decode(&msg)
	return msg, err
}
