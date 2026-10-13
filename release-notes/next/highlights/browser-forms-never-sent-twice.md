title: A form is never sent twice by surprise
category: fixed

A browser tab that shows the result of a form (a payment, a delete) now stays loaded when cmux saves memory, so waking it cannot send the form again. In WebKit tabs, when Duplicate Tab, Reopen Closed Tab, Reload or Back would send a form again, the tab asks first.
