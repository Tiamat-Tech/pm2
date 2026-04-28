'use strict'

var path = require('path')
var execSync = require('child_process').execSync
var Common = require('./Common')
var cst = require('../constants')

var PM2_ROOT = path.join(__dirname, '..')

var OTEL_PACKAGES = [
  '@opentelemetry/api',
  '@opentelemetry/sdk-node',
  '@opentelemetry/auto-instrumentations-node',
  '@opentelemetry/core',
  '@opentelemetry/sdk-trace-base',
  '@opentelemetry/semantic-conventions'
]

module.exports = {
  OTEL_PACKAGES: OTEL_PACKAGES,

  isInstalled: function() {
    try {
      require.resolve('@opentelemetry/sdk-node')
      return true
    } catch(e) {
      return false
    }
  },

  install: function() {
    Common.printOut(cst.PREFIX_MSG + 'Installing OpenTelemetry tracing packages...')
    execSync('npm install --no-save ' + OTEL_PACKAGES.join(' '), {
      cwd: PM2_ROOT,
      stdio: 'inherit'
    })
    Common.printOut(cst.PREFIX_MSG + 'OpenTelemetry tracing packages installed successfully')
  },

  uninstall: function() {
    Common.printOut(cst.PREFIX_MSG + 'Removing OpenTelemetry tracing packages...')
    execSync('npm uninstall --no-save ' + OTEL_PACKAGES.join(' '), {
      cwd: PM2_ROOT,
      stdio: 'inherit'
    })
    Common.printOut(cst.PREFIX_MSG + 'OpenTelemetry tracing packages removed')
  },

  ensureInstalled: function() {
    if (this.isInstalled()) return true
    try {
      this.install()
      return true
    } catch(e) {
      Common.printError(cst.PREFIX_MSG_ERR + 'Failed to install OpenTelemetry packages: ' + e.message)
      Common.printError(cst.PREFIX_MSG_ERR + 'Install manually with: pm2 install-otel')
      return false
    }
  }
}
