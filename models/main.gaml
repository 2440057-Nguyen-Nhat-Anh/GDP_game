/**
* Name: main
* Based on the internal empty template. 
* Author: anhnh
* Tags: 
*/


model main

global {
	file shapefile_buildings <- file("../includes/buildings.shp");
	file shapefile_roads <- file("../includes/roads.shp");
	
	geometry shape <- envelope(shapefile_roads);
	
	graph road_network;
	
	road hover_road <- nil;
	road selected_road <- nil;
	
	building hover_building <- nil;
	
	map<road, float> new_weight;
	
	float step <- 10#s;
	date starting_date <- date([2024, 1, 1, 7, 0, 0]);
	
	reflex update_speed {
		new_weight <- road as_map (each::each.shape.perimeter/each.speed_rate);	
	}
	
	init {
		list<geometry> lines <- split_lines(shapefile_roads);
		create road from: lines;
		
		write "Created roads: " + length(road);
				
		road_network <- as_edge_graph(road);

		create building from: shapefile_buildings with: (height: int(read("HEIGHT")));
		write "Number of buildings: " + length(building);
        

		list<building> sorted_buildings <- (building where (each.shape.area > 9000)) sort_by (-each.shape.area);
      
        ask 8 among sorted_buildings { 
            type <- "factory"; 
            capacity <- 0; 
        }
        
        list<building> frontage <- building where (each.type = nil and each distance_to (road closest_to each) < 15.0);
        ask 5 among frontage { type <- "bank"; }
        ask 10 among frontage { type <- "market"; }
        
        ask building where (each.type = nil) { 
            type <- "home"; 
            capacity <- 4; 
        }
		
		create inhabitant number: 1000 {
            building home <- one_of(building where (each.type = "home" and length(each.residents) < each.capacity));
            
            if (home != nil) {
                location <- any_location_in(home);
                add self to: home.residents;
            } else {
                location <- any_location_in(one_of(building));
            }
        }
	}
}

species building {
    float height;
    string type;
    int capacity <- 4;
    list<inhabitant> residents;

    aspect default {
        rgb b_color <- #gray;
        
        if (self = hover_building) {
        	b_color <- #white;
        } else {        	
	        switch type {
	            match "bank" { 
	            	b_color <- #yellow;
	            }
	            match "factory" { 
	            	b_color <- #orange;
	            }
	            match "market" { 
	            	b_color <- #cyan;
	            }
	        }
        }
        
        draw shape color: b_color border: #black;
    }
}

species road {
	float capacity <- 1 + shape.perimeter / 30;
	int nb_drivers <- 0 update: length(inhabitant at_distance 1);
	float speed_rate <- 1.0 update: exp(-nb_drivers / capacity) min: 0.1;
	
	aspect default {
		rgb road_color <- nil;
		
		if (self = selected_road) {
			road_color <- #purple;
		} else if (self = hover_road) {
			road_color <- #blue;
		} else {
			road_color <- blend(#red, #pink, 1 - speed_rate);
		}
		
		float thickness <- (1 + 3 * (1 - speed_rate));
		draw (shape buffer (1 + 3 * (1 - speed_rate))) color: road_color;
	}
}

species inhabitant skills: [moving] {
	point target;
	building home;
	building workplace;
	string status <- "resting";
	
	float proba_leave <- 0.05;
	float speed <- 5 #km/#h;
    
    init {
    	workplace <- one_of(building where (each.type = "factory"));	
    }

    reflex move when: (target != nil) {
        do goto target: target on: road_network move_weights: new_weight;
        if (location = target) { 
        	target <- nil;
        }
    }
    
    reflex schedule {
	    int h <- current_date.hour;
	    int m <- current_date.minute;
	
	    if (target != nil) {
//	    	write "Target = "+ target;
//	    	write "Location = "+ location;
	        if (location distance_to target < 50.0) {
	            if (status = "going_to_work") { 
	                status <- "working";
	                target <- nil; 
	            } else if (status = "shopping" or status = "banking") {
	                target <- any_location_in(home);
	                status <- "going_home";
	            } else if (status = "going_home") {
	                status <- "resting";
	                target <- nil;
	            }
	        }
	    }
	    
	    if (target = nil) {
	        float r <- rnd(0.0, 1.0);
	        
	        if (h = 7 and m >= 30 and status = "resting") {
	            target <- any_location_in(workplace);
	            status <- "going_to_work";
	        } else if (h >= 8 and h < 12 and status = "resting") {
	            target <- any_location_in(workplace);
	            status <- "going_to_work";
	        } else if (h = 17 and m = 30 and status = "working") {
	            if (r < 0.3) {
	                target <- any_location_in(one_of(building where (each.type = "market")));
	                status <- "shopping";
	            } else if (r < 0.4) {
	                target <- any_location_in(one_of(building where (each.type = "bank")));
	                status <- "banking";
	            } else {
	                target <- any_location_in(home);
	                status <- "going_home";
	            }
	        } else if (h >= 22 and status != "resting") {
	            target <- any_location_in(home);
	            status <- "going_home";
	        }
	    }
	}
	
	aspect default {
		draw circle(5) color: #lightgreen;
	}
}


experiment project type: gui {
	output {
		display map type: 3d axes: false background: #black{
			species building aspect: default;
			species road aspect: default;			
			species inhabitant aspect: default;
			
			event mouse_down {
				point m_pos <- #user_location;
				
				ask world {
//					ask road {
//						is_selected <- false;
//					}
					road r <- road closest_to m_pos;
					if (r != nil and (r distance_to m_pos < 15.0)) {
						selected_road <- r;
//						r.is_selected <- true;
						write "You just clicked: " + selected_road;
					} else {
						selected_road <- nil;
					}
					
					building b <- building closest_to m_pos;
					if (b != nil and (b distance_to m_pos < 10.0)) {
						hover_building <- b;
						write "You just clicked building id: " + b + " size: " + b.shape.area;
					} else {
						hover_building <- nil;
					}
				}
			}
			
			event mouse_move {
                point m_pos <- #user_location;
                
                ask world {
//                	ask road {
//                		is_hovered <- false;
//                	}
                    road r <- road closest_to m_pos;
                    if (r != nil and (r distance_to m_pos < 15.0)) {
                        hover_road <- r;
//                        r.is_hovered <- true;
                    } else {
                        hover_road <- nil;
                    }
                    
                    building b <- building closest_to m_pos;
                    if (b != nil and (b distance_to m_pos < 10.0)) {
                    	hover_building <- b;
                    } else {
                    	hover_building <- nil;
                    }
                }
            }
            
            overlay position: {50#px, 50#px} size: {200#px, 350#px} background: #white border: #white transparency: 0.1 {
				float y <- 30#px;
				draw "Color Note" at: {20#px, y} color: #black font: font("Arial", 14, #bold);
				
				y <- y + 30#px;
				draw square(15#px) at: {30#px, y} color: #yellow;
				draw "Bank" at: {55#px, y + 8#px} color: #black font: font("Arial", 12);
				
				y <- y + 30#px;
				draw square(15#px) at: {30#px, y} color: #orange;
				draw "Factory" at: {55#px, y + 8#px} color: #black font: font("Arial", 12);
				
				y <- y + 30#px;
				draw square(15#px) at: {30#px, y} color: #cyan;
				draw "Market" at: {55#px, y + 8#px} color: #black font: font("Arial", 12);
				
				y <- y + 30#px;
				draw square(15#px) at: {30#px, y} color: #gray;
				draw "Home" at: {55#px, y + 8#px} color: #black font: font("Arial", 12);
				
				y <- y + 30#px;
				draw circle(8#px) at: {30#px, y} color: #lightgreen;
				draw "Inhabitant" at: {55#px, y + 8#px} color: #black font: font("Arial", 12);
				
				y <- y + 40#px;
				draw line([{20#px, y}, {180#px, y}]) color: #black;
				
				y <- y + 40#px;
				draw "Road:" at: {20#px, y} color: #black font: font("Arial", 11, #italic);
				draw "Traffic jam -> Normal" at: {20#px, y + 20#px} color: #black font: font("Arial", 12);
				
				y <- y + 45#px;
				draw "Time" at: {20#px, y} color: #black font: font("Arial", 15, #bold);
				
				y <- y + 20#px;
				draw string(current_date, "dd / MM / yyyy") at: {20#px, y} color: #black font: font("Arial", 12);
				draw string(current_date, "HH:mm") at: {100#px, y} color: #black font: font("Arial", 14, #bold);
			}
		}
	}
}
