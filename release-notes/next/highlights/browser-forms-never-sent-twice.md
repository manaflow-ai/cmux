title: A form is never sent twice by surprise
category: fixed
action: openBrowser | New Browser Tab

A tab that shows the result of a form, such as a payment, stays loaded when cmux saves memory, so waking it can't send the form again. WebKit tabs ask before Reload, Back or Duplicate Tab resend a form.
