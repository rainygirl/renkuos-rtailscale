// lockstress reproduces the Haiku/386 startup hang in seconds instead of hours.
//
// A plain hello-world hangs about 1 run in 40-80 at GOMAXPROCS=2, which is far
// too rare to investigate. This exercises the paths the hang implicates - m
// creation, park/unpark, and runtime mutex traffic - and hangs about 8 runs in
// 20 on the same hardware. Timers were tried too and are innocent (0 in 20).
//
// Build for the target and loop it:
//
//	CGO_ENABLED=0 GOOS=haiku GOARCH=386 go build -o lockstress lockstress.go
//	# then on the box, with a 5s kill timeout per run
//
// It exits immediately on success, so a run still alive after a few seconds has
// hung. Always run at GOMAXPROCS=2 or more; at GOMAXPROCS=1 it effectively never
// hangs, which is why the port pins everything to one P.
package main

import (
	"os"
	"sync"
)

func main() {
	var wg sync.WaitGroup
	var mu sync.Mutex
	n := 0
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 5000; j++ {
				mu.Lock()
				n++
				mu.Unlock()
			}
		}()
	}
	ch := make(chan int)
	done := make(chan struct{})
	go func() {
		for range ch {
		}
		close(done)
	}()
	for i := 0; i < 5000; i++ {
		ch <- i
	}
	close(ch)
	<-done
	wg.Wait()
	os.Stdout.WriteString("ok\n")
}
