// Copyright 2008, 2009 Chris Forno
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

// This is for the original link creation page.
function showLinkEditor() {
  var linkType = this.options[this.selectedIndex].text.replace(/ /g, '-');
  $('fieldset').hide();
  $('#' + linkType).show();
}

// This is for editing in-place on an already-created link page.
function editLink() {
  var linkDetails = $('#link-details');
  var box = linkDetails.parent().find('textarea:first');
  box.show();
  linkDetails.hide();
  box.markItUp(mySettings);
}

$(document).ready(function() {
  var linkTypeSelector = $('select[name=fval4]:first');
  linkTypeSelector.change(showLinkEditor);
  linkTypeSelector.change();
  $('#link-edit').click(editLink);
});