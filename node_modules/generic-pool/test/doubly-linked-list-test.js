var tap = require("tap");
var DLL = require("../lib/DoublyLinkedList");

tap.test("operations", function(t) {
  var dll = new DLL();

  var item1 = { id: 1 };
  var item2 = { id: 2 };
  var item3 = { id: 3 };
  var item4 = { id: 4 };

  dll.insertBeginning(DLL.createNode(item1));
  t.equal(dll.head.data, item1);

  dll.insertEnd(DLL.createNode(item2));
  t.equal(dll.tail.data, item2);

  dll.insertAfter(dll.tail, DLL.createNode(item3));
  t.equal(dll.tail.data, item3);

  dll.insertBefore(dll.tail, DLL.createNode(item4));
  t.equal(dll.tail.data, item3);

  dll.remove(dll.tail);
  t.equal(dll.tail.data, item4);

  t.end();
});
