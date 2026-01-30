/*global it, describe, beforeEach */

var stream = require("stream");
var fs = require("mz/fs");
var assert = require("assert");
var util = require("util");

var promisePipe = require("./index");
var StreamError = promisePipe.StreamError;

var INPUT = __dirname + "/fixtures/input.txt";
var OUTPUT = __dirname + "/fixtures/output.txt";

function Upcase(){
    stream.Transform.call(this);
}

function W () {
    stream.Writable.call(this);
}

function raise(err) {
  throw err;
}

util.inherits(Upcase, stream.Transform);
util.inherits(W, stream.Writable);

Upcase.prototype._transform = function(chunk, encoding, cb) {
    if (/X/.test(chunk.toString())) {
        cb(new Error("X is not allowed"));
        return;
    }
    this.str = (this.str || '') + chunk.toString();
    this.push(chunk.toString().toUpperCase());
    cb();
};

Upcase.prototype._flush = function(cb) {
    setTimeout(() => {
        if (/Y/.test(this.str)) {
            cb(new Error("Y is not allowed"));
            return;
        }
        cb()
    }, 1);
};

W.prototype._write = function () {
    this.emit("error", new Error("Write failed"));
    this.emit("error", new Error("Write failed"));
};

describe("promisePipe", function() {

    beforeEach(function() {
        return fs
          .unlink(OUTPUT)
          .catch(err => err.code === "ENOENT" || raise(err));
    });

    it("can do basic piping", function() {
        var input = fs.createReadStream(INPUT);
        var output = fs.createWriteStream(OUTPUT);

        return promisePipe(input, output).then(function(pipeChain) {

            assert.equal(input, pipeChain[0], "Resolved promise passes stream pipe chain back");
            assert.equal(output, pipeChain[1]);

            return fs
              .readFile(OUTPUT)
              .then(data => assert.equal(data.toString().trim(), "foobar"));
        });
    });

    ["stdout", "stderr"].forEach(function(stdio) {
        it("can pipe to " + stdio, function() {
            var input = fs.createReadStream(INPUT);
            return promisePipe(input, process[stdio]);
        });

        it("can handle errors when dest is " + stdio, function() {
            var input = fs.createReadStream("bad");
            var output = process[stdio];

            return promisePipe(input, output)
              .catch(err => err)
              .then(function(err) {
                assert(err);
                assert.equal(err.originalError.code, "ENOENT");
                assert.equal(err.source, input);
              });
        });
    });

    it("can handle errors from source", function() {
        var input = fs.createReadStream("bad");
        var output = fs.createWriteStream(OUTPUT);

        return promisePipe(input, output)
          .catch(err => err)
          .then(function(err) {
            assert(err);
            assert.equal(err.originalError.code, "ENOENT");
            assert.equal(err.source, input);
          });
    });

    it("can handle errors from target", function() {
        var input = fs.createReadStream(INPUT);
        var output = fs.createWriteStream("/bad");

        return promisePipe(input, output)
          .catch(err => err)
          .then(function(err) {
            assert(err);
            assert.ok([ "EACCES", "EPERM" ].includes(err.originalError.code));
          });
    });

    it("can pipe via transforms", function() {
        var input = fs.createReadStream(INPUT);
        var output = fs.createWriteStream(OUTPUT);

        return promisePipe(input, new Upcase(), output).then(function() {
            return fs
              .readFile(OUTPUT)
              .then(data => assert.equal(data.toString().trim(), "FOOBAR"));
        });
    });

    it("can handle errors from transforms", function() {
        var input = fs.createReadStream(INPUT + ".x");
        var output = fs.createWriteStream(OUTPUT);

        return promisePipe(input, new Upcase(), output)
          .catch(err => err)
          .then(function(err) {
            assert(err);
            assert.equal(err.originalError.message, "X is not allowed");
        });
    });

    it("can handle errors from _flush in transforms", function() {
        var input = fs.createReadStream(INPUT + ".y");
        var output = fs.createWriteStream(OUTPUT);

        const upcase = new Upcase()
        return promisePipe(input, upcase, output)
          .catch(err => err)
          .then(function(err) {
            assert(err);
            assert.equal(err.originalError.message, "Y is not allowed");
        });
    });

    it("can handle multiple errors", function() {
        var input = fs.createReadStream(INPUT);

        return promisePipe(input, new W())
          .catch(err => err)
          .then(function(err) {
            assert(err);
            assert.equal(err.originalError.message, "Write failed");
        });
    });

    it("closes streams on errors", function() {
        var input = fs.createReadStream(INPUT + ".x");
        var output = fs.createWriteStream(OUTPUT);

        return promisePipe(input, new Upcase(), output)
          .catch(err => err)
          .then(function() {
            return fs.unlink(OUTPUT);
          });
    });

    it("resolves chains with transform streams on error", function() {
        var input = fs.createReadStream(INPUT);
        var output = fs.createWriteStream("/bad");

        return promisePipe(input, new Upcase(), output)
          .catch(err => err)
          .then(function(err) {
            assert(err);
            assert.ok([ "EACCES", "EPERM" ].includes(err.originalError.code));
          });
    });
});

describe('StreamError', function() {
    it('uses the provided error message', function() {
        var err = new StreamError({message: 'foo'});
        assert.equal(err.message,'foo');
    });

    it('uses assign message as error string param', function() {
        var err = new StreamError('foo');
        assert.equal(err.message,'foo');
    });

    it('should not throw if no message', function() {
        var err = new StreamError();
        assert.equal(err.message,'');
    });
});
