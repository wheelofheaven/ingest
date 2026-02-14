// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/curator"
import topbar from "../vendor/topbar"

// Custom hooks
const ScrollSpy = {
  mounted() {
    this.visibleSet = new Set()
    this.debounce = null
    this.currentRefId = null
    this.setupObserver()
  },

  updated() {
    this.setupObserver()
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    if (this.debounce) clearTimeout(this.debounce)
  },

  setupObserver() {
    if (this.observer) this.observer.disconnect()
    this.visibleSet.clear()

    this.observer = new IntersectionObserver(
      (entries) => {
        entries.forEach(entry => {
          if (entry.isIntersecting) {
            this.visibleSet.add(entry.target)
          } else {
            this.visibleSet.delete(entry.target)
          }
        })

        if (this.debounce) clearTimeout(this.debounce)
        this.debounce = setTimeout(() => {
          let topmost = null
          let topY = Infinity
          this.visibleSet.forEach(target => {
            const rect = target.getBoundingClientRect()
            if (rect.top >= 0 && rect.top < topY) {
              topY = rect.top
              topmost = target
            }
          })
          // Fallback: if nothing has top >= 0, pick the one closest to top
          if (!topmost) {
            this.visibleSet.forEach(target => {
              const rect = target.getBoundingClientRect()
              if (Math.abs(rect.top) < Math.abs(topY)) {
                topY = rect.top
                topmost = target
              }
            })
          }

          if (topmost) {
            const refId = topmost.dataset.refId
            if (refId && refId !== this.currentRefId) {
              this.currentRefId = refId
              this.pushEvent("scroll_focus", {"ref-id": refId})
            }
          }
        }, 80)
      },
      { threshold: 0 }
    )

    this.el.querySelectorAll("[data-ref-id]").forEach(el => {
      this.observer.observe(el)
    })
  }
}

const ContentEditable = {
  mounted() {
    this._handleBlur = () => this.save()
    this._handleKeydown = (e) => {
      if (e.key === "Escape") {
        e.preventDefault()
        this.cancel()
      }
    }
  },

  updated() {
    const editing = this.el.dataset.editing === "true"
    if (editing && !this.el.isContentEditable) {
      this.activate()
    } else if (!editing && this.el.isContentEditable) {
      this.deactivate()
    }
  },

  activate() {
    this.originalText = this.el.innerText
    this.el.contentEditable = "true"
    this.el.focus()
    // Place cursor at end
    const range = document.createRange()
    range.selectNodeContents(this.el)
    range.collapse(false)
    const sel = window.getSelection()
    sel.removeAllRanges()
    sel.addRange(range)

    this.el.addEventListener("blur", this._handleBlur)
    this.el.addEventListener("keydown", this._handleKeydown)
  },

  deactivate() {
    this.el.contentEditable = "false"
    this.el.removeEventListener("blur", this._handleBlur)
    this.el.removeEventListener("keydown", this._handleKeydown)
  },

  save() {
    const text = this.el.innerText.trim()
    if (text !== this.originalText) {
      this.pushEvent("save_paragraph", {
        ref_id: this.el.dataset.refId,
        text: text
      })
    } else {
      this.pushEvent("cancel_edit", {})
    }
    this.deactivate()
  },

  cancel() {
    this.el.innerText = this.originalText
    this.deactivate()
    this.pushEvent("cancel_edit", {})
  },

  destroyed() {
    this.deactivate()
  }
}

const ShiftClick = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      this.pushEvent("toggle_select", {
        "ref-id": this.el.dataset.refId,
        "shift": e.shiftKey
      })
      e.preventDefault()
    })
  }
}

const Hooks = {...colocatedHooks, ScrollSpy, ContentEditable, ShiftClick}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

