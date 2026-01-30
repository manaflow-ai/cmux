const tap = require("tap");
const DLL = require("../lib/DoublyLinkedList");
const Iterator = require("../lib/DoublyLinkedListIterator");

tap.test("iterates forward", function(t) {
  const dll = new DLL();

  const node1 = DLL.createNode({ id: 1 });
  const node2 = DLL.createNode({ id: 2 });
  const node3 = DLL.createNode({ id: 3 });
  const node4 = DLL.createNode({ id: 4 });

  dll.insertBeginning(node1);
  dll.insertBeginning(node2);
  dll.insertBeginning(node3);
  dll.insertBeginning(node4);

  const iterator = new Iterator(dll);

  const iterationResult1 = iterator.next();
  t.notOk(iterationResult1.done);
  t.same(iterationResult1.value, node4);

  iterator.next();
  iterator.next();

  const iterationResult4 = iterator.next();
  t.notOk(iterationResult4.done);
  t.same(iterationResult4.value, node1);

  const iterationResult5 = iterator.next();
  t.ok(iterationResult5.done);

  t.end();
});

tap.test("iterates backwards", function(t) {
  const dll = new DLL();

  const node1 = DLL.createNode({ id: 1 });
  const node2 = DLL.createNode({ id: 2 });
  const node3 = DLL.createNode({ id: 3 });
  const node4 = DLL.createNode({ id: 4 });

  dll.insertBeginning(node1);
  dll.insertBeginning(node2);
  dll.insertBeginning(node3);
  dll.insertBeginning(node4);

  const iterator = new Iterator(dll, true);

  const iterationResult1 = iterator.next();
  t.notOk(iterationResult1.done);
  t.same(iterationResult1.value, node1);

  iterator.next();
  iterator.next();

  const iterationResult4 = iterator.next();
  t.notOk(iterationResult4.done);
  t.same(iterationResult4.value, node4);

  const iterationResult5 = iterator.next();
  t.ok(iterationResult5.done);

  t.end();
});

tap.test("iterates forward when adding nodes after creating iterator", function(
  t
) {
  const dll = new DLL();

  const node1 = DLL.createNode({ id: 1 });
  const node2 = DLL.createNode({ id: 2 });

  const iterator = new Iterator(dll);

  dll.insertBeginning(node1);
  dll.insertBeginning(node2);

  const iterationResult1 = iterator.next();
  t.notOk(iterationResult1.done);
  t.same(iterationResult1.value, node2);

  const iterationResult2 = iterator.next();
  t.notOk(iterationResult2.done);
  t.same(iterationResult2.value, node1);

  const iterationResult3 = iterator.next();
  t.ok(iterationResult3.done);

  t.end();
});

tap.test(
  "iterates backwards when adding nodes after creating iterator",
  function(t) {
    const dll = new DLL();

    const node1 = DLL.createNode({ id: 1 });
    const node2 = DLL.createNode({ id: 2 });

    const iterator = new Iterator(dll, true);

    dll.insertBeginning(node1);
    dll.insertBeginning(node2);

    const iterationResult1 = iterator.next();
    t.notOk(iterationResult1.done);
    t.same(iterationResult1.value, node1);

    const iterationResult2 = iterator.next();
    t.notOk(iterationResult2.done);
    t.same(iterationResult2.value, node2);

    const iterationResult3 = iterator.next();
    t.ok(iterationResult3.done);

    t.end();
  }
);

tap.test("stops iterating when node is detached", function(t) {
  const dll = new DLL();
  const iterator = new Iterator(dll);

  const node1 = DLL.createNode({ id: 1 });
  const node2 = DLL.createNode({ id: 2 });

  dll.insertBeginning(node1);
  dll.insertBeginning(node2);

  const iterationResult1 = iterator.next();
  t.notOk(iterationResult1.done);
  t.same(iterationResult1.value, node2);

  dll.remove(node1);

  const iterationResult3 = iterator.next();
  t.ok(iterationResult3.done);

  t.end();
});
