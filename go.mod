// ax-lab: a learning track for github.com/google/ax
//
// The replace directive points at the local upstream clone so examples build
// against the real source (and IDE go-to-definition lands in ax's actual code)
// instead of a published copy that can drift.
module axlab

go 1.27.1

replace github.com/google/ax => ./upstream/google-ax

require (
	github.com/google/ax v0.0.0-00010101000000-000000000000
	google.golang.org/protobuf v1.36.12
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/kr/text v0.2.0 // indirect
	golang.org/x/net v0.58.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.41.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260720211330-0afa2a65878a // indirect
	google.golang.org/grpc v1.83.2 // indirect
)
