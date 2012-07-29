var DEBUG = false;

$(function () {
  var status = $("#status");
  var api_key = $("input[name='api_key']");
  api_key.val(localStorage.getItem("api_key") || "");

  $("form").submit(function () {
    var app_name = $("input[name='app_name']").val();
    localStorage.setItem("api_key", api_key.val());
    $("form input[type='submit']").hide();
    $("form input").attr("disabled", "disabled");
    status.show();

    var client = new Pusher($("html").attr("data-pusher-key")).subscribe(app_name);

    client.bind("log", function (data) {
      status.text(data);
      DEBUG && console.log(data);
    });

    client.bind("error", function (message) {
      status.text(message);
      alert("Something went wrong.");
    });

    client.bind("complete", function (message) {
      var url = "http://" + app_name + ".herokuapp.com/";
      var event = document.createEvent("MouseEvents");
      event.initMouseEvent("click", true, true, window, 0, 0, 0, 0, 0, false, false, false, false, 1, null);
      $("<a />").attr("href", url)[0].dispatchEvent(event);
      status.text(message);
    });

    status.text("Connecting to Heroku ...");

    $.post(location.href, { app_name: app_name, api_key: api_key.val() });
    return false;
  });
});
