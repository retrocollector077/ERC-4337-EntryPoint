(function () {
  function forwardLog(method, ...args) {
    parent.postMessage({
      type: 'forward-log',
      method,
      // TODO a more robust serializer
      message: args
        .map((a) => {
          try {
            return JSON.stringify(a, null, 0);
          } catch {
            return 'Error: console message could not be stringified';
          }
        })
        .join(' '),
    });
  }

  const logMethods = new Set([
    'log',
    'warn',
    'error',
    'info',
    'debug',
    'table',
    'assert',
  ]);

  const proxiedConsole = new Proxy(console, {
    get(target, prop, receiver) {
      const original = Reflect.get(target, prop, receiver);

      if (typeof original === 'function' && logMethods.has(prop)) {
        return (...args) => {
          forwardLog(prop, args);

          return original.apply(target, args);
        };
      }

      return original;
    },
  });

  // replace the global console with our proxy
  try {
    window.console = proxiedConsole;
  } catch {
    // fallback: copy enumerable function properties instead
    Object.keys(proxiedConsole).forEach((key) => {
      try {
        window.console[key] = proxiedConsole[key];
      } catch { /* ignore */ }
    });
  }

  function forwardNetworkRequest(message) {
    parent.postMessage({
      type: 'forward-network-request',
      message,
    });
  }

  window.addEventListener('error', (event) => {
    const err = event.error;

    if (err instanceof Error) {
      forwardLog('unhandlederror', {
        message: err.message,
        stack: err.stack,
        type: err.type,
      });
    } else if (typeof err === 'string') {
      forwardLog('unhandlederror', {
        message: err,
      });
    } else {
      forwardLog('unhandlederror', {
        message:
          'An uncaught exception occured but the error was not an error object.',
      });
    }
  });

  window.addEventListener('unhandledrejection', (event) => {
    if (event.reason instanceof Error) {
      forwardLog('unhandledrejection', {
        message: event.reason.message,
        stack: event.reason.stack,
        type: event.reason.type,
      });
    } else if (typeof event.reason === 'string') {
      forwardLog('unhandledrejection', {
        message: event.reason,
      });
    } else {
      forwardLog('unhandledrejection', {
        message:
          'An unhandled rejection occured but the error was not an error object.',
      });
    }
  });

  const historyEvent = '__replit-history-event'

  /**
   * Serializes request body based on its type
   * @param {*} body - Request body to serialize
   * @returns {string} Serialized body or error message
   */
  function serializeRequestBody(body) {
    if (!body) return undefined;

    try {
      if (typeof body === 'string') {
        return body;
      }

      if (body instanceof ArrayBuffer || body instanceof Uint8Array || body instanceof Blob) {
        return '[binary]';
      }

      if (body instanceof FormData) {
        const entries = Array.from(body.entries());
        return 'FormData: ' + entries
          .map(([key, value]) => {
            if (value instanceof File) {
              return `${key}=File(name: ${value.name}, size: ${value.size}bytes)`;
            }
            return `${key}=${value}`;
          })
          .join('&');
      }

      if (body instanceof URLSearchParams) {
        return body.toString();
      }

      return JSON.stringify(body);
    } catch (error) {
      return 'Could not serialize request body';
    }
  }

  /**
   * Extracts headers from request configuration
   * @param {Object} config - Request configuration
   * @returns {Object} Headers as plain object
   */
  function extractHeaders(config) {
    if (!config?.headers) return {};

    try {
      if (config.headers instanceof Headers) {
        return Object.fromEntries(config.headers.entries());
      }
      return config.headers;
    } catch {
      return {};
    }
  }

  /**
   * Creates request info object for logging
   * @param {Array} fetchArgs - Arguments passed to fetch()
   * @returns {Object} Request information
   */
  function createRequestInfo(fetchArgs) {
    const [url, config] = fetchArgs;

    return {
      // Trying our best to get the url, if it's a object, hope it's in the url property
      url: (typeof url === 'string' ? url : (url instanceof Request ? url.url : url?.url)) || '',
      method: config?.method || 'GET',
      origin: window.location.origin,
      timestamp: new Date().toISOString(),
      requestHeaders: extractHeaders(config),
      requestBody: serializeRequestBody(config?.body)
    };
  }

  /**
   * Extracts response body based on content type
   * @param {Response} response - Fetch response object
   * @returns {Promise<*>} Parsed response body
   */
  async function extractResponseBody(response) {
    if (!response.clone) {
      return 'Could not read response body';
    }

    try {
      const clonedResponse = response.clone();
      const contentType = clonedResponse.headers.get('content-type');

      if (contentType && contentType.includes('application/json')) {
        return await clonedResponse.json();
      }
      return await clonedResponse.text();
    } catch {
      return 'Could not read response body';
    }
  }

  /**
   * Creates a Proxy-based fetch interceptor
   */
  window.fetch = new Proxy(window.fetch, {
    apply: async (target, thisArg, argArray) => {
      const requestInfo = createRequestInfo(argArray);

      try {
        // Execute the original fetch request
        const response = await target.apply(thisArg, argArray);

        // Extract and forward response details
        const responseBody = await extractResponseBody(response);

        const responseInfo = {
          ...requestInfo,
          status: response.status,
          statusText: response.statusText,
          responseBody: responseBody,
          responseHeaders: Object.fromEntries(response.headers.entries()),
        };

        forwardNetworkRequest(responseInfo);

        return response;

      } catch (error) {
        // Handle network errors
        const errorInfo = {
          ...requestInfo,
          error: {
            message: error?.message || 'Unknown fetch error',
            stack: error?.stack || 'Stack trace not available'
          }
        };

        forwardNetworkRequest(errorInfo);

        // Re-throw the error to maintain normal error flow
        throw error;
      }
    }
  });

  window.history.pushState = new Proxy(window.history.pushState, {
    apply: (target, thisArg, argArray) => {
      Promise.resolve().then(() => {
        window.dispatchEvent(new Event(historyEvent));
      });

      return Reflect.apply(target, thisArg, argArray);
    },
  });

  window.history.replaceState = new Proxy(window.history.replaceState, {
    apply: (target, thisArg, argArray) => {
      Promise.resolve().then(() => {
        window.dispatchEvent(new Event(historyEvent));
      });

      return Reflect.apply(target, thisArg, argArray);
    },
  });
})();
