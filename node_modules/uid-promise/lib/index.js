// Packages
const crypto = require('crypto')

// Utilities
const UIDCHARS = require('./chars')

module.exports = len => new Promise((resolve, reject) => {
  if (typeof len !== 'number') {
    reject(new TypeError('You must supply a length integer to `uid-promise`.'))
    return
  }

  crypto.randomBytes(len, (err, buf) => {
    if (err) {
      return reject(err)
    }
    const str = []
    for (let i = 0; i < buf.length; i++) {
      str.push(UIDCHARS[buf[i] % UIDCHARS.length])
    }
    resolve(str.join(''))
  })
})
