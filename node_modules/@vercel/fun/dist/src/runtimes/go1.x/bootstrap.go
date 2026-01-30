// Credits:
//   https://github.com/lambci/docker-lambda/blob/f6b4765a9b659ceb949c34b19390026820ddd462/go1.x/run/aws-lambda-mock.go
//   https://binx.io/blog/2018/12/03/aws-lambda-custom-bootstrap-in-go

package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"github.com/aws/aws-lambda-go/lambda/messages"
	"github.com/phayes/freeport"
	"io/ioutil"
	"log"
	"math/rand"
	"net"
	"net/http"
	"net/rpc"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"reflect"
	"strconv"
	"syscall"
	"time"
)

func main() {
	rand.Seed(time.Now().UTC().UnixNano())

	mockContext := &MockLambdaContext{
		FnName:    getEnv("AWS_LAMBDA_FUNCTION_NAME", "test"),
		Handler:   getEnv("AWS_LAMBDA_FUNCTION_HANDLER", getEnv("_HANDLER", "handler")),
		Version:   getEnv("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST"),
		MemSize:   getEnv("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "1536"),
		Timeout:   getEnv("AWS_LAMBDA_FUNCTION_TIMEOUT", "300"),
		Region:    getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-east-1")),
		AccountId: getEnv("AWS_ACCOUNT_ID", strconv.FormatInt(int64(rand.Int31()), 10)),
		Start:     time.Now(),
		Pid:       1,
	}
	mockContext.ParseTimeout()

	awsAccessKey := getEnv("AWS_ACCESS_KEY", getEnv("AWS_ACCESS_KEY_ID", "SOME_ACCESS_KEY_ID"))
	awsSecretKey := getEnv("AWS_SECRET_KEY", getEnv("AWS_SECRET_ACCESS_KEY", "SOME_SECRET_ACCESS_KEY"))
	awsSessionToken := getEnv("AWS_SESSION_TOKEN", os.Getenv("AWS_SECURITY_TOKEN"))
	taskRoot := getEnv("LAMBDA_TASK_ROOT", "/var/task")

	handlerPath := path.Join(taskRoot, mockContext.Handler)

	os.Setenv("AWS_LAMBDA_FUNCTION_NAME", mockContext.FnName)
	os.Setenv("AWS_LAMBDA_FUNCTION_VERSION", mockContext.Version)
	os.Setenv("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", mockContext.MemSize)
	os.Setenv("AWS_LAMBDA_LOG_GROUP_NAME", "/aws/lambda/"+mockContext.FnName)
	os.Setenv("AWS_LAMBDA_LOG_STREAM_NAME", logStreamName(mockContext.Version))
	os.Setenv("AWS_REGION", mockContext.Region)
	os.Setenv("AWS_DEFAULT_REGION", mockContext.Region)
	os.Setenv("_HANDLER", mockContext.Handler)

	port, err := freeport.GetFreePort()
	if err != nil {
		log.Fatal(fmt.Errorf("Freeport Error %s", err))
	}
	portStr := strconv.Itoa(port)

	var cmd *exec.Cmd
	cmd = exec.Command(handlerPath)

	cmd.Env = append(os.Environ(),
		"_LAMBDA_SERVER_PORT="+portStr,
		"AWS_ACCESS_KEY="+awsAccessKey,
		"AWS_ACCESS_KEY_ID="+awsAccessKey,
		"AWS_SECRET_KEY="+awsSecretKey,
		"AWS_SECRET_ACCESS_KEY="+awsSecretKey,
	)

	if len(awsSessionToken) > 0 {
		cmd.Env = append(cmd.Env,
			"AWS_SESSION_TOKEN="+awsSessionToken,
			"AWS_SECURITY_TOKEN="+awsSessionToken,
		)
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	if err = cmd.Start(); err != nil {
		defer abortRequest(mockContext, err)
		return
	}

	mockContext.Pid = cmd.Process.Pid
	p, _ := os.FindProcess(-mockContext.Pid)
	defer p.Signal(syscall.SIGKILL)

	// Terminate the child process upon SIGINT / SIGTERM
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		p, _ := os.FindProcess(-mockContext.Pid)
		p.Signal(syscall.SIGKILL)

		os.Exit(0)
	}()

	var conn net.Conn
	for {
		conn, err = net.Dial("tcp", ":"+portStr)
		if mockContext.HasExpired() {
			defer abortRequest(mockContext, mockContext.TimeoutErr())
			return
		}
		if err == nil {
			break
		}
		if oerr, ok := err.(*net.OpError); ok {
			// Connection refused, try again
			if oerr.Op == "dial" && oerr.Net == "tcp" {
				time.Sleep(5 * time.Millisecond)
				continue
			}
		}
		defer abortRequest(mockContext, err)
		return
	}

	mockContext.Rpc = rpc.NewClient(conn)

	for {
		err = mockContext.Rpc.Call("Function.Ping", messages.PingRequest{}, &messages.PingResponse{})
		if mockContext.HasExpired() {
			defer abortRequest(mockContext, mockContext.TimeoutErr())
			return
		}
		if err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	// XXX: The Go runtime seems to amortize the startup time, reset it here
	mockContext.Start = time.Now()

	// If we got to here then the handler process has initialized successfully
	mockContext.ProcessEvents()
}

func abortRequest(mockContext *MockLambdaContext, err error) {
	log.Fatal(err)
}

func getEnv(key, fallback string) string {
	value := os.Getenv(key)
	if value != "" {
		return value
	}
	return fallback
}

func logStreamName(version string) string {
	randBuf := make([]byte, 16)
	rand.Read(randBuf)

	hexBuf := make([]byte, hex.EncodedLen(len(randBuf)))
	hex.Encode(hexBuf, randBuf)

	return time.Now().Format("2006/01/02") + "/[" + version + "]" + string(hexBuf)
}

func getErrorType(err interface{}) string {
	if errorType := reflect.TypeOf(err); errorType.Kind() == reflect.Ptr {
		return errorType.Elem().Name()
	} else {
		return errorType.Name()
	}
}

type LambdaError struct {
	Message    string                                      `json:"errorMessage"`
	Type       string                                      `json:"errorType,omitempty"`
	StackTrace []*messages.InvokeResponse_Error_StackFrame `json:"stackTrace,omitempty"`
}

type MockLambdaContext struct {
	Pid             int
	FnName          string
	Handler         string
	Version         string
	MemSize         string
	Timeout         string
	Region          string
	AccountId       string
	Start           time.Time
	TimeoutDuration time.Duration
	Reply           *messages.InvokeResponse
	Rpc             *rpc.Client
}

func (mc *MockLambdaContext) ProcessEvents() {
	awsLambdaRuntimeApi := os.Getenv("AWS_LAMBDA_RUNTIME_API")
	if awsLambdaRuntimeApi == "" {
		panic("Missing: 'AWS_LAMBDA_RUNTIME_API'")
	}
	for {
		// get the next event
		requestUrl := fmt.Sprintf("http://%s/2018-06-01/runtime/invocation/next", awsLambdaRuntimeApi)
		resp, err := http.Get(requestUrl)
		if err != nil {
			log.Fatal(fmt.Errorf("Error getting next invocation: %v", err))
		}

		requestId := resp.Header.Get("Lambda-Runtime-Aws-Request-Id")
		eventData, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			log.Fatal(fmt.Errorf("Error reading body: %s", err))
		}

		err = mc.Rpc.Call("Function.Invoke", mc.Request(requestId, eventData), &mc.Reply)
		if err != nil {
			log.Fatal(fmt.Errorf("Error invoking RPC call: %s", err))
		}

		responseUrl := fmt.Sprintf("http://%s/2018-06-01/runtime/invocation/%s/response", awsLambdaRuntimeApi, requestId)
		req, err := http.NewRequest("POST", responseUrl, bytes.NewBuffer(mc.Reply.Payload))
		if err != nil {
			log.Fatal(fmt.Errorf("Error creating response HTTP request: %s", err))
		}
		req.Header.Set("Content-Type", "application/json")

		client := &http.Client{}
		client.Timeout = 0
		_, err = client.Do(req)
		if err != nil {
			log.Fatal(fmt.Errorf("Error sending response: %s", err))
		}
	}
}

func (mc *MockLambdaContext) ParseTimeout() {
	timeoutDuration, err := time.ParseDuration(mc.Timeout + "s")
	if err != nil {
		panic(err)
	}
	mc.TimeoutDuration = timeoutDuration
}

func (mc *MockLambdaContext) Deadline() time.Time {
	return mc.Start.Add(mc.TimeoutDuration)
}

func (mc *MockLambdaContext) HasExpired() bool {
	return time.Now().After(mc.Deadline())
}

func (mc *MockLambdaContext) Request(requestId string, payload []byte) *messages.InvokeRequest {
	return &messages.InvokeRequest{
		Payload:            payload,
		RequestId:          requestId,
		XAmznTraceId:       getEnv("_X_AMZN_TRACE_ID", ""),
		InvokedFunctionArn: getEnv("AWS_LAMBDA_FUNCTION_INVOKED_ARN", ""),
		Deadline: messages.InvokeRequest_Timestamp{
			Seconds: mc.Deadline().Unix(),
			Nanos:   int64(mc.Deadline().Nanosecond()),
		},
	}
}

func (mc *MockLambdaContext) TimeoutErr() error {
	return fmt.Errorf("%s %s Task timed out after %s.00 seconds", time.Now().Format("2006-01-02T15:04:05.999Z"),
		"1234", mc.Timeout)
}
