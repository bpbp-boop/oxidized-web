var convertTime = function() {
  /* Convert UTC times to local browser times
  *  Requires that the times on the server are UTC
  *  Requires a class name of `time` to be set on element desired to be changed
  *  Requires that element has an attribute `epoch` containing the seconds since
  *  1.1.1970 UTC.
  */
  $('.time').each(function() {
    var content = $(this).text();
    if(content === 'never' || content === 'unknown' || content === '') {
      return;
    }
    var epoch = $(this).attr('epoch');
    if(epoch === undefined) {
      return;
    }
    var utcTime = Number(epoch);
    var dj = dayjs.unix(utcTime).local();

    $(this).text(dj.format('YYYY-MM-DD HH:mm:ss [(UTC]Z[)]'));
  });
};

/*
 * Persist DataTables controls in both the URL and this browser tab's session.
 *
 * URL state takes precedence so shared links are deterministic. When a URL has
 * no DataTables state, sessionStorage supplies the last state used for that
 * table. DataTables calls the save callback after each draw and visibility
 * change, so the URL remains current without adding entries to browser history.
 */
var dataTableStateOptions = function(tableId) {
  var stateParameter = 'dt_state';
  var sessionKey = 'oxidized.datatable.v1.' + tableId;

  var readInteger = function(value, minimum) {
    if(value === null || !/^-?\d+$/.test(value)) {
      return null;
    }

    var parsed = Number(value);
    if(!Number.isSafeInteger(parsed) || parsed < minimum) {
      return null;
    }

    return parsed;
  };

  var readOrder = function(value, columnCount) {
    if(value === '') {
      return [];
    }
    if(value === null) {
      return null;
    }

    var order = [];
    var entries = value.split(',');
    for(var i = 0; i < entries.length; i++) {
      var match = entries[i].match(/^(\d+):(asc|desc)$/);
      if(match === null) {
        return null;
      }

      var column = Number(match[1]);
      if(column >= columnCount) {
        return null;
      }
      order.push([column, match[2]]);
    }

    return order;
  };

  var stateFromUrl = function(settings, parameters) {
    if(parameters.get(stateParameter) !== tableId) {
      return null;
    }

    var columnCount = settings.aoColumns.length;
    var length = readInteger(parameters.get('dt_length'), -1);
    if(length === 0) {
      length = null;
    }
    var start = readInteger(parameters.get('dt_start'), 0);
    var order = readOrder(parameters.get('dt_order'), columnCount);
    var visibility = parameters.get('dt_columns');
    var visibilityIsValid = visibility !== null &&
      visibility.length === columnCount &&
      /^[01]+$/.test(visibility);

    var columns = settings.aoColumns.map(function(column, index) {
      return {
        name: column.sName || '',
        visible: visibilityIsValid ? visibility[index] === '1' : column.bVisible,
        search: {}
      };
    });

    return {
      time: Date.now(),
      start: start === null ? 0 : start,
      length: length === null ? settings._iDisplayLength : length,
      order: order === null ? settings.aaSorting : order,
      search: {
        search: parameters.get('dt_search') || '',
        regex: false,
        smart: true,
        caseInsensitive: true
      },
      columns: columns
    };
  };

  var stateFromSession = function() {
    try {
      var state = JSON.parse(window.sessionStorage.getItem(sessionKey));
      if(state && typeof state === 'object' && state.time) {
        return state;
      }
    }
    catch(error) {
      // Storage can be disabled or contain data from an interrupted write.
    }

    return null;
  };

  var saveToSession = function(state) {
    try {
      window.sessionStorage.setItem(sessionKey, JSON.stringify(state));
    }
    catch(error) {
      // URL persistence still works when session storage is unavailable.
    }
  };

  var saveToUrl = function(state) {
    if(!window.history || !window.history.replaceState) {
      return;
    }

    var url = new URL(window.location.href);
    var parameters = url.searchParams;
    parameters.set(stateParameter, tableId);
    parameters.set('dt_length', String(state.length));
    parameters.set('dt_start', String(state.start));
    parameters.set('dt_order', state.order.map(function(order) {
      return order[0] + ':' + order[1];
    }).join(','));
    parameters.set('dt_columns', state.columns.map(function(column) {
      return column.visible ? '1' : '0';
    }).join(''));
    parameters.set('dt_search', state.search && state.search.search ?
      state.search.search : '');

    if(url.href !== window.location.href) {
      window.history.replaceState(window.history.state, document.title, url.href);
    }
  };

  return {
    stateSave: true,
    stateDuration: -1,
    stateLoadCallback: function(settings) {
      var parameters = new URL(window.location.href).searchParams;
      return stateFromUrl(settings, parameters) || stateFromSession();
    },
    stateSaveCallback: function(settings, state) {
      saveToSession(state);
      saveToUrl(state);
    }
  };
};

$(function() {
  convertTime();

  // Reloads the nodes from a source by calling the /reload.json URI
  $('#reload').click(function() {
    $.get(window.location.pathname.replace(/nodes.*/g, '')+'reload.json')
      .done(function(data) {
        $('#flashMessage')
        .removeClass('alert-danger')
        .addClass('alert-success')
        .text(data);
      })
      .fail(function() {
        var data = 'Unable to reload nodes'
        $('#flashMessage')
          .removeClass('alert-success')
          .addClass('alert-danger')
          .text(data);
      })
      .always(function() {
        $('#flashMessage').removeClass('hidden');
      });
  });

  // Update timestamp on next button click for DataTables
  $('.paginate_button').on('click', function() {
    convertTime();
  });
});
