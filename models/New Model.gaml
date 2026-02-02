/**
* Name: NewModel
* Based on the internal empty template. 
* Author: anhnh
* Tags: 
*/


model NewModel

/* Insert your model definition here */

global {
	file shapefile_buildings <- file("../includes/buildings.shp");
	file shapefile_roads <- file("../includes/roads.shp");
	
	geometry shape <- envelope(shapefile_roads);
	
	graph road_network;
	
	map<road, float> new_weight;
	
	reflex update_speed {
		new_weight <- road as_map (each::each.shape.perimeter/each.speed_rate);	
	}
	
	init {
		create building from: shapefile_buildings with: (height: int(read("HEIGHT")));
		create road from: shapefile_roads;
		
		create inhabitant number: 1000 {
			location <- any_location_in(one_of(building));
		}
		
		road_network <- as_edge_graph(road);
	}
}

species building{
	float height;
	aspect default{
		draw shape color: #gray border: #yellow;
	} 
}

species road {
	float capacity <- 1 + shape.perimeter / 30;
	int nb_drivers <- 0 update: length(inhabitant at_distance 1);
	float speed_rate <- 1.0 update: exp(-nb_drivers / capacity) min: 0.1;
	
	aspect default {
		draw (shape buffer (1 + 3 * (1 - speed_rate))) color: #red;
	}
}

species inhabitant skills: [moving] {
	point target;
	rgb color <- rnd_color(255);
	float proba_leave <- 0.05;
	float speed <- 5 #km/#h;
	
	reflex leave when: (target = nil) and (flip(proba_leave)) {
		target <- any_location_in(one_of(building));
	}
	
	reflex move when: (target != nil) {
		do goto target: target on: road_network move_weights: new_weight;
		if (location = target) {
			target <- nil;
		}
	}
	
	aspect default {
		draw circle(5) color: color;
	}
}


experiment project type: gui {
	output {
		display map type: 3d axes: false background: #black{
			species building aspect: default refresh: false;
			species road aspect: default;			
			species inhabitant aspect: default;
		}
	}
}