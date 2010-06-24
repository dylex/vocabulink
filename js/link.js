// Copyright 2009, 2010 Chris Forno
//
// This file is part of Vocabulink.
//
// Vocabulink is free software: you can redistribute it and/or modify it under
// the terms of the GNU Affero General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option) any
// later version.
//
// Vocabulink is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
// details.
//
// You should have received a copy of the GNU Affero General Public License
// along with Vocabulink. If not, see <http://www.gnu.org/licenses/>.

function annotateLink(link) {
  link.children().each(function () {
    var word = $(this);
    var caption = $('<span class="caption">' + word.attr('title') + '</span>');
    // We have to calculate these before we add content to them and screw up
    // the dimensions.
    var width = word.outerWidth();
    if (word.hasClass('.orig') || word.hasClass('.dest')) {
      var y = word.outerHeight() + 4;
    } else {
      var y = word.height() + 8;
    }
    caption.appendTo(word);
    var x = (width - caption.width()) / 2;
    caption.css({'position': 'absolute', 'left': x, 'top': y});
  });
}

$(document).ready(function () {
  annotateLink($('h1.link:visible'));

  // "add to review"
  $('#link-op-review.enabled').click(function () {
    var op = $(this);
    op.mask("Adding...");
    var linkNum = window.location.pathname.split('/').pop();
    $.postJSON('/review/' + linkNum + '/add', null, function (successful, data) {
      op.unmask();
      op.removeClass("enabled").addClass("disabled");
      if (successful) {
        op.text("now reviewing");
      } else {
        op.addClass("failed");
        op.text("Failed!");
      }
    });
  });

  // "delete link"
  $('#link-op-delete.enabled').click(function () {
    var op = $(this);
    op.mask("Deleting...");
    var linkNum = window.location.pathname.split('/').pop();
    $.postJSON('/link/' + linkNum + '/delete', null, function (successful, data) {
      op.unmask();
      op.removeClass("enabled").addClass("disabled");
      if (successful) {
        op.text("deleted");
      } else {
        op.addClass("failed");
        op.text("Failed!");
      }
    });
  });
});
