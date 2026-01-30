"use strict";

const tap = require("tap");
const createPool = require("../").createPool;
const utils = require("./utils");
const ResourceFactory = utils.ResourceFactory;

// tap.test('Pool expands only to max limit', function (t) {
//   const resourceFactory = new ResourceFactory()

//   const config = {
//     max: 1
//   }

//   const pool = createPool(resourceFactory, config)

//     // NOTES:
//     // - request a resource
//     // - once we have it, request another and check the pool is fool
//   pool.acquire(function (err, obj) {
//     t.error(err)
//     const poolIsFull = !pool.acquire(function (err, obj) {
//       t.error(err)
//       t.equal(1, resourceFactory.created)
//       pool.release(obj)
//       utils.stopPool(pool)
//       t.end()
//     })
//     t.ok(poolIsFull)
//     t.equal(1, resourceFactory.created)
//     pool.release(obj)
//   })
// })

// tap.test('Pool respects min limit', function (t) {
//   const resourceFactory = new ResourceFactory()

//   const config
//     min: 1,
//     max: 2
//   }

//   const pool = createPool(resourceFactory, config)

//     // FIXME: this logic only works because we know it takes ~1ms to create a resource
//     // we need better hooks into the pool probably to observe this...
//   setTimeout(function () {
//     t.equal(resourceFactory.created, 1)
//     utils.stopPool(pool)
//     t.end()
//   }, 10)
// })

tap.test("min and max limit defaults", function(t) {
  const resourceFactory = new ResourceFactory();

  const pool = createPool(resourceFactory);

  t.equal(1, pool.max);
  t.equal(0, pool.min);
  utils.stopPool(pool);
  t.end();
});

tap.test("malformed min and max limits are ignored", function(t) {
  const resourceFactory = new ResourceFactory();

  const config = {
    min: "asf",
    max: []
  };
  const pool = createPool(resourceFactory, config);

  t.equal(1, pool.max);
  t.equal(0, pool.min);
  utils.stopPool(pool);
  t.end();
});

tap.test("min greater than max sets to max", function(t) {
  const resourceFactory = new ResourceFactory();

  const config = {
    min: 5,
    max: 3
  };
  const pool = createPool(resourceFactory, config);

  t.equal(3, pool.max);
  t.equal(3, pool.min);
  utils.stopPool(pool);
  t.end();
});

tap.test("supports priority on borrow", function(t) {
  // NOTE: this test is pretty opaque about what it's really testing/expecting...
  let borrowTimeLow = 0;
  let borrowTimeHigh = 0;
  let borrowCount = 0;

  const resourceFactory = new ResourceFactory();

  const config = {
    max: 1,
    priorityRange: 2
  };

  const pool = createPool(resourceFactory, config);

  function lowPriorityOnFulfilled(obj) {
    const time = Date.now();
    if (time > borrowTimeLow) {
      borrowTimeLow = time;
    }
    borrowCount++;
    pool.release(obj);
  }

  function highPriorityOnFulfilled(obj) {
    const time = Date.now();
    if (time > borrowTimeHigh) {
      borrowTimeHigh = time;
    }
    borrowCount++;
    pool.release(obj);
  }

  const operations = [];

  for (let i = 0; i < 10; i++) {
    const op = pool.acquire(1).then(lowPriorityOnFulfilled);
    operations.push(op);
  }

  for (let i = 0; i < 10; i++) {
    const op = pool.acquire(0).then(highPriorityOnFulfilled);
    operations.push(op);
  }

  Promise.all(operations)
    .then(function() {
      t.equal(20, borrowCount);
      t.equal(true, borrowTimeLow >= borrowTimeHigh);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

// FIXME: bad test!
// pool.destroy makes no obligations to user about when it will destroy the resource
// we should test that "destroyed" objects are not acquired again instead
// tap.test('removes correct object on reap', function (t) {
//   const resourceFactory = new ResourceFactory()

//   const config
//     max: 2
//   }

//   const pool = createPool(resourceFactory, config)

//   const op1 = pool.acquire()
//   .then(function (client) {
//     return new Promise(function (resolve, reject) {
//       // should be removed second
//       setTimeout(function () {
//         pool.destroy(client)
//         resolve()
//       }, 5)
//     })
//   })

//   const op2 = pool.acquire()
//   .then(function (client) {
//     pool.destroy(client)
//   })

//   Promise.all([op1, op2]).then(function () {
//     t.equal(1, resourceFactory.bin[0].id)
//     t.equal(0, resourceFactory.bin[1].id)
//     utils.stopPool(pool)
//     t.end()
//   })
//   .catch(t.threw)
// })

tap.test("evictor removes instances on idletimeout", function(t) {
  const resourceFactory = new ResourceFactory();
  const config = {
    min: 2,
    max: 2,
    idleTimeoutMillis: 50,
    evictionRunIntervalMillis: 10
  };
  const pool = createPool(resourceFactory, config);

  setTimeout(function() {
    pool
      .acquire()
      .then(res => {
        t.ok(res.id > 1);
        return pool.release(res);
      })
      .then(() => {
        utils.stopPool(pool);
        t.end();
      });
  }, 120);
});

tap.test("tests drain", function(t) {
  const count = 5;
  let acquired = 0;

  const resourceFactory = new ResourceFactory();
  const config = {
    max: 2,
    idletimeoutMillis: 300000
  };
  const pool = createPool(resourceFactory, config);

  const operations = [];

  function onAcquire(client) {
    acquired += 1;
    t.equal(typeof client.id, "number");
    setTimeout(function() {
      pool.release(client);
    }, 250);
  }

  // request 5 resources that release after 250ms
  for (let i = 0; i < count; i++) {
    const op = pool.acquire().then(onAcquire);
    operations.push(op);
  }
  // FIXME: what does this assertion prove?
  t.notEqual(count, acquired);

  Promise.all(operations)
    .then(function() {
      return pool.drain();
    })
    .then(function() {
      t.equal(count, acquired);
      // short circuit the absurdly long timeouts above.
      pool.clear();
    })
    .then(function() {
      // subsequent calls to acquire should resolve an error.
      return pool.acquire().then(t.fail, function(e) {
        t.type(e, Error);
      });
    })
    .then(function() {
      t.end();
    });
});

tap.test("handle creation errors", function(t) {
  let created = 0;
  const resourceFactory = {
    create: function() {
      created++;
      if (created < 5) {
        return Promise.reject(new Error("Error occurred."));
      } else {
        return Promise.resolve({ id: created });
      }
    },
    destroy: function(client) {}
  };
  const config = {
    max: 1
  };

  const pool = createPool(resourceFactory, config);

  // FIXME: this section no longer proves anything as factory
  // errors no longer bubble up through the acquire call
  // we need to make the Pool an Emitter

  // ensure that creation errors do not populate the pool.
  // for (const i = 0; i < 5; i++) {
  //   pool.acquire(function (err, client) {
  //     t.ok(err instanceof Error)
  //     t.ok(client === null)
  //   })
  // }

  let called = false;
  pool
    .acquire()
    .then(function(client) {
      t.equal(typeof client.id, "number");
      called = true;
      pool.release(client);
    })
    .then(function() {
      t.ok(called);
      t.equal(pool.pending, 0);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

tap.test("handle creation errors for delayed creates", function(t) {
  let attempts = 0;

  const resourceFactory = {
    create: function() {
      attempts++;
      if (attempts <= 5) {
        return Promise.reject(new Error("Error occurred."));
      } else {
        return Promise.resolve({ id: attempts });
      }
    },
    destroy: function(client) {
      return Promise.resolve();
    }
  };

  const config = {
    max: 1
  };

  const pool = createPool(resourceFactory, config);

  let errorCount = 0;
  pool.on("factoryCreateError", function(err) {
    t.ok(err instanceof Error);
    errorCount++;
  });

  let called = false;
  pool
    .acquire()
    .then(function(client) {
      t.equal(typeof client.id, "number");
      called = true;
      pool.release(client);
    })
    .then(function() {
      t.ok(called);
      t.equal(errorCount, 5);
      t.equal(pool.pending, 0);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

tap.test("getPoolSize", function(t) {
  let assertionCount = 0;
  const resourceFactory = new ResourceFactory();
  const config = {
    max: 2
  };

  const pool = createPool(resourceFactory, config);

  const borrowedResources = [];

  t.equal(pool.size, 0);
  assertionCount += 1;

  pool
    .acquire()
    .then(function(obj) {
      borrowedResources.push(obj);
      t.equal(pool.size, 1);
      assertionCount += 1;
    })
    .then(function() {
      return pool.acquire();
    })
    .then(function(obj) {
      borrowedResources.push(obj);
      t.equal(pool.size, 2);
      assertionCount += 1;
    })
    .then(function() {
      pool.release(borrowedResources.shift());
      pool.release(borrowedResources.shift());
    })
    .then(function() {
      return pool.acquire();
    })
    .then(function(obj) {
      // should still be 2
      t.equal(pool.size, 2);
      assertionCount += 1;
      pool.release(obj);
    })
    .then(function() {
      t.equal(assertionCount, 4);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

tap.test("availableObjectsCount", function(t) {
  let assertionCount = 0;
  const resourceFactory = new ResourceFactory();
  const config = {
    max: 2
  };

  const pool = createPool(resourceFactory, config);

  const borrowedResources = [];

  t.equal(pool.available, 0);
  assertionCount += 1;

  pool
    .acquire()
    .then(function(obj) {
      borrowedResources.push(obj);
      t.equal(pool.available, 0);
      assertionCount += 1;
    })
    .then(function() {
      return pool.acquire();
    })
    .then(function(obj) {
      borrowedResources.push(obj);
      t.equal(pool.available, 0);
      assertionCount += 1;
    })
    .then(function() {
      pool.release(borrowedResources.shift());
      t.equal(pool.available, 1);
      assertionCount += 1;

      pool.release(borrowedResources.shift());
      t.equal(pool.available, 2);
      assertionCount += 1;
    })
    .then(function() {
      return pool.acquire();
    })
    .then(function(obj) {
      t.equal(pool.available, 1);
      assertionCount += 1;
      pool.release(obj);

      t.equal(pool.available, 2);
      assertionCount += 1;
    })
    .then(function() {
      t.equal(assertionCount, 7);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

// FIXME: bad test!
// pool.destroy makes no obligations to user about when it will destroy the resource
// we should test that "destroyed" objects are not acquired again instead
// tap.test('removes from available objects on destroy', function (t) {
//   let destroyCalled = false
//   const factory = {
//     create: function () { return Promise.resolve({}) },
//     destroy: function (client) { destroyCalled = true; return Promise.resolve() }
//   }

//   const config
//     max: 2
//   }

//   const pool = createPool(factory, config)

//   pool.acquire().then(function (obj) {
//     pool.destroy(obj)
//   })
//   .then(function () {
//     t.equal(destroyCalled, true)
//     t.equal(pool.available, 0)
//     utils.stopPool(pool)
//     t.end()
//   })
//   .catch(t.threw)
// })

// FIXME: bad test!
// pool.destroy makes no obligations to user about when it will destroy the resource
// we should test that "destroyed" objects are not acquired again instead
// tap.test('removes from available objects on validation failure', function (t) {
//   const destroyCalled = false
//   const validateCalled = false
//   const count = 0
//   const factory = {
//     create: function () { return Promise.resolve({count: count++}) },
//     destroy: function (client) { destroyCalled = client.count },
//     validate: function (client) {
//       validateCalled = true
//       return Promise.resolve(client.count > 0)
//     }
//   }

//   const config
//     max: 2,
//     testOnBorrow: true
//   }

//   const pool = createPool(factory, config)

//   pool.acquire()
//   .then(function (obj) {
//     pool.release(obj)
//     t.equal(obj.count, 0)
//   })
//   .then(function () {
//     return pool.acquire()
//   })
//   .then(function (obj2) {
//     pool.release(obj2)
//     t.equal(obj2.count, 1)
//   })
//   .then(function () {
//     t.equal(validateCalled, true)
//     t.equal(destroyCalled, 0)
//     t.equal(pool.available, 1)
//     utils.stopPool(pool)
//     t.end()
//   })
//   .catch(t.threw)
// })

tap.test(
  "do schedule again if error occured when creating new Objects async",
  function(t) {
    // NOTE: we're simulating the first few resource attempts failing
    let resourceCreationAttempts = 0;

    const factory = {
      create: function() {
        resourceCreationAttempts++;
        if (resourceCreationAttempts < 2) {
          return Promise.reject(new Error("Create Error"));
        }
        return Promise.resolve({});
      },
      destroy: function(client) {}
    };

    const config = {
      max: 1
    };

    const pool = createPool(factory, config);
    // pool.acquire(function () {})
    pool
      .acquire()
      .then(function(obj) {
        t.equal(pool.available, 0);
        pool.release(obj);
        utils.stopPool(pool);
        t.end();
      })
      .catch(t.threw);
  }
);

tap.test("returns only valid object to the pool", function(t) {
  const pool = createPool(new ResourceFactory(), { max: 1 });

  pool
    .acquire()
    .then(function(obj) {
      t.equal(pool.available, 0);
      t.equal(pool.borrowed, 1);

      // Invalid release
      pool
        .release({})
        .catch(function(err) {
          t.match(err.message, /Resource not currently part of this pool/);
        })
        .then(function() {
          t.equal(pool.available, 0);
          t.equal(pool.borrowed, 1);

          // Valid release
          pool.release(obj).catch(t.error);
          t.equal(pool.available, 1);
          t.equal(pool.borrowed, 0);
          utils.stopPool(pool);
          t.end();
        });
    })
    .catch(t.threw);
});

tap.test("validate acquires object from the pool", function(t) {
  const pool = createPool(new ResourceFactory(), { max: 1 });

  pool
    .acquire()
    .then(function(obj) {
      t.equal(pool.available, 0);
      t.equal(pool.borrowed, 1);
      pool.release(obj);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

tap.test("release to pool should work", function(t) {
  const pool = createPool(new ResourceFactory(), { max: 1 });

  pool
    .acquire()
    .then(function(obj) {
      t.equal(pool.available, 0);
      t.equal(pool.borrowed, 1);
      t.equal(pool.pending, 1);
      pool.release(obj);
    })
    .catch(t.threw);

  pool
    .acquire()
    .then(function(obj) {
      t.equal(pool.available, 0);
      t.equal(pool.borrowed, 1);
      t.equal(pool.pending, 0);
      pool.release(obj);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

tap.test(
  "isBorrowedResource should return true for borrowed resource",
  function(t) {
    const pool = createPool(new ResourceFactory(), { max: 1 });

    pool
      .acquire()
      .then(function(obj) {
        t.equal(pool.isBorrowedResource(obj), true);
        pool.release(obj);
        utils.stopPool(pool);
        t.end();
      })
      .catch(t.threw);
  }
);

tap.test(
  "isBorrowedResource should return false for released resource",
  function(t) {
    const pool = createPool(new ResourceFactory(), { max: 1 });

    pool
      .acquire()
      .then(function(obj) {
        pool.release(obj);
        return obj;
      })
      .then(function(obj) {
        t.equal(pool.isBorrowedResource(obj), false);
        utils.stopPool(pool);
        t.end();
      })
      .catch(t.threw);
  }
);

tap.test("destroy should redispense", function(t) {
  const pool = createPool(new ResourceFactory(), { max: 1 });

  pool
    .acquire()
    .then(function(obj) {
      t.equal(pool.available, 0);
      t.equal(pool.borrowed, 1);
      t.equal(pool.pending, 1);
      pool.destroy(obj);
    })
    .catch(t.threw);

  pool
    .acquire()
    .then(function(obj) {
      t.equal(pool.available, 0);
      t.equal(pool.borrowed, 1);
      t.equal(pool.pending, 0);
      pool.release(obj);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

tap.test("evictor start with acquire when autostart is false", function(t) {
  const pool = createPool(new ResourceFactory(), {
    evictionRunIntervalMillis: 10000,
    autostart: false
  });

  t.equal(pool._scheduledEviction, null);

  pool
    .acquire()
    .then(function(obj) {
      t.notEqual(pool._scheduledEviction, null);
      pool.release(obj);
      utils.stopPool(pool);
      t.end();
    })
    .catch(t.threw);
});

tap.test("use method", function(t) {
  const pool = createPool(new ResourceFactory());
  const result = pool.use(function(resource) {
    t.equal(0, resource.id);
    return Promise.resolve();
  });
  result.then(function() {
    t.end();
  });
});

tap.test("use method should resolve after fn promise is resolved", function(t) {
  const pool = createPool(new ResourceFactory());
  let done_with_resource = false;
  const result = pool.use(function(resource) {
    return new Promise(function(resolve, reject) {
      setImmediate(function() {
        done_with_resource = true;
        resolve("value");
      });
    });
  });
  result.then(val => {
    t.equal(done_with_resource, true);
    t.equal(val, "value");
    t.end();
  });
});
